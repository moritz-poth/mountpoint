// Spiegel-Helfer von Mountpoint: hängt einen Ordner als eigenes Volume ein (macFUSE, libfuse 2).
// Aufruf: mirror <Quellordner> <Mountpunkt> -o volname=<Name>
// shortcut: reiner Durchgriff ohne Caching-Optionen; erst optimieren, wenn Avid-Wiedergabe darüber ruckelt.
#define FUSE_USE_VERSION 26
#define _DARWIN_USE_64_BIT_INODE
#include <fuse.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/time.h>
#include <sys/xattr.h>
#include <unistd.h>
#include <libproc.h>
#include <pthread.h>
#include <sys/mount.h>
#include <time.h>

static char root[PATH_MAX];

// Pfad im Volume -> Pfad im Quellordner
static const char *real(const char *path, char *buf) {
    snprintf(buf, PATH_MAX, "%s%s", root, path);
    return buf;
}
#define REAL(p) char _b[PATH_MAX]; const char *r = real(p, _b)
#define TRY(x) return (x) == -1 ? -errno : 0

static int m_getattr(const char *p, struct stat *st) { REAL(p); TRY(lstat(r, st)); }
static int m_access(const char *p, int mask) { REAL(p); TRY(access(r, mask)); }
static int m_readlink(const char *p, char *buf, size_t size) {
    REAL(p);
    ssize_t n = readlink(r, buf, size - 1);
    if (n == -1) return -errno;
    buf[n] = 0;
    return 0;
}
static int m_readdir(const char *p, void *buf, fuse_fill_dir_t fill, off_t off, struct fuse_file_info *fi) {
    REAL(p);
    DIR *d = opendir(r);
    if (!d) return -errno;
    struct dirent *e;
    while ((e = readdir(d))) {
        struct stat st = {0};
        st.st_ino = e->d_ino;
        st.st_mode = DTTOIF(e->d_type);
        if (fill(buf, e->d_name, &st, 0)) break;
    }
    closedir(d);
    return 0;
}
static int m_mkdir(const char *p, mode_t mode) { REAL(p); TRY(mkdir(r, mode)); }
// Papierkorb: Als Netzlaufwerk gibt macOS dem Volume keinen Papierkorb, der Finder würde sofort löschen.
// Löscht der Finder (bzw. sein Hilfsprozess), verschieben wir die Datei stattdessen in den Papierkorb des Laufwerks,
// auf dem der Quellordner liegt (gleiches Dateisystem → sofort). Der Finder löscht Ordner Datei für Datei; die Teile
// sammeln sich darum kurz in einem versteckten Zwischenordner. Kurz nach dem letzten Löschen landet das oberste
// gelöschte Element unter seinem Namen im Papierkorb – so wie bei macOS. Andere Programme (z. B. Avid) löschen normal.
static pthread_mutex_t trash_lock = PTHREAD_MUTEX_INITIALIZER;
static char trash_base[PATH_MAX];   // .Trashes/<uid> des Quelllaufwerks bzw. ~/.Trash
static char staging[PATH_MAX];      // versteckter Zwischenordner darin
static time_t last_delete;

static int from_finder(void) {
    pid_t pid = fuse_get_context()->pid;
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (pid <= 0 || proc_pidpath(pid, path, sizeof path) <= 0) return 0;
    // Der Finder lässt das Löschen meist von seinem Hilfsprozess DesktopServicesHelper ausführen
    return strstr(path, "/Finder.app/") != NULL || strstr(path, "/DesktopServicesPriv.framework/") != NULL;
}

static int mkdirs(const char *dir, mode_t mode) {
    char tmp[PATH_MAX];
    snprintf(tmp, sizeof tmp, "%s", dir);
    for (char *c = tmp + 1; *c; c++) {
        if (*c != '/') continue;
        *c = 0;
        if (mkdir(tmp, mode) == -1 && errno != EEXIST) return -1;
        *c = '/';
    }
    return mkdir(tmp, mode) == -1 && errno != EEXIST ? -1 : 0;
}

static void trash_paths(void) {
    if (trash_base[0]) return;
    struct statfs fs;
    const char *home = getenv("HOME");
    if (statfs(root, &fs) == 0 && (strcmp(fs.f_mntonname, "/") && strcmp(fs.f_mntonname, "/System/Volumes/Data")))
        snprintf(trash_base, sizeof trash_base, "%s/.Trashes/%d", fs.f_mntonname, getuid());
    else if (home)
        snprintf(trash_base, sizeof trash_base, "%s/.Trash", home);   // Systemvolume: Papierkorb des Benutzers
    const char *name = strrchr(root, '/');
    snprintf(staging, sizeof staging, "%s/.mountpoint-%s", trash_base, name ? name + 1 : "volume");
}

// freier Name im Papierkorb: "1", "1 2", "1 3" …
static void unique(const char *dir, const char *name, char *out) {
    snprintf(out, PATH_MAX, "%s/%s", dir, name);
    for (int i = 2; access(out, F_OK) == 0 && i < 10000; i++) snprintf(out, PATH_MAX, "%s/%s %d", dir, name, i);
}

// Gelöschte Elemente aus dem Zwischenordner in den Papierkorb: Ein Ordner, den es im Volume noch gibt, war nur
// Behälter (hineinsehen); was es nicht mehr gibt, wurde gelöscht und wandert unter seinem Namen in den Papierkorb.
static void flush_dir(const char *rel) {
    char sdir[PATH_MAX];
    snprintf(sdir, sizeof sdir, "%s%s", staging, rel);
    DIR *d = opendir(sdir);
    if (!d) return;
    char names[256][NAME_MAX + 1];
    int n = 0;
    struct dirent *e;
    while ((e = readdir(d)) && n < 256) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        snprintf(names[n++], NAME_MAX + 1, "%s", e->d_name);
    }
    closedir(d);
    for (int i = 0; i < n; i++) {
        char childrel[PATH_MAX], staged[PATH_MAX], source[PATH_MAX], target[PATH_MAX];
        snprintf(childrel, sizeof childrel, "%s/%s", rel, names[i]);
        snprintf(staged, sizeof staged, "%s%s", staging, childrel);
        snprintf(source, sizeof source, "%s%s", root, childrel);
        struct stat ss, st;
        if (lstat(staged, &ss) == 0 && S_ISDIR(ss.st_mode) && lstat(source, &st) == 0 && S_ISDIR(st.st_mode)) {
            flush_dir(childrel);
        } else {
            unique(trash_base, names[i], target);
            rename(staged, target);
        }
    }
    if (n == 256) flush_dir(rel);   // mehr als 256 Einträge: weiter
    else if (rel[0]) rmdir(sdir);
}

static void flush_trash(void) {
    pthread_mutex_lock(&trash_lock);
    trash_paths();
    flush_dir("");
    rmdir(staging);
    last_delete = 0;
    pthread_mutex_unlock(&trash_lock);
}

// Hintergrund: zwei Sekunden nach dem letzten Löschen aufräumen
static void *trash_worker(void *arg) {
    for (;;) {
        sleep(1);
        pthread_mutex_lock(&trash_lock);
        int due = last_delete && time(NULL) - last_delete >= 2;
        pthread_mutex_unlock(&trash_lock);
        if (due) flush_trash();
    }
    return NULL;
}

static void *m_init(struct fuse_conn_info *conn) {
    flush_trash();   // Reste einer früheren Sitzung (z. B. nach Absturz) nicht verstecken
    pthread_t t;
    pthread_create(&t, NULL, trash_worker, NULL);
    pthread_detach(t);
    return NULL;
}

static void m_destroy(void *data) { flush_trash(); }

// Datei in den Zwischenordner; Fehler statt endgültigem Löschen, falls das nicht geht
static int to_trash(const char *p, const char *r) {
    pthread_mutex_lock(&trash_lock);
    trash_paths();
    char dest[PATH_MAX], dir[PATH_MAX];
    snprintf(dest, sizeof dest, "%s%s", staging, p);
    snprintf(dir, sizeof dir, "%s", dest);
    char *slash = strrchr(dir, '/');
    if (slash) *slash = 0;
    int rc = -1;
    if (mkdirs(dir, 0700) == 0) {
        // gleiche Datei vor dem Aufräumen zweimal gelöscht: ältere zuerst wegräumen
        if (access(dest, F_OK) == 0) {
            char target[PATH_MAX];
            const char *name = strrchr(dest, '/') + 1;
            unique(trash_base, name, target);
            rename(dest, target);
        }
        rc = rename(r, dest);
    }
    int err = errno;
    last_delete = time(NULL);
    pthread_mutex_unlock(&trash_lock);
    errno = err;
    return rc;
}

static int m_unlink(const char *p) {
    REAL(p);
    if (from_finder()) TRY(to_trash(p, r));
    TRY(unlink(r));
}

// Ordner: Leere Ordner wandern selbst in den Papierkorb. Bei Ordnern mit Inhalt liegen die Dateien schon im
// Zwischenordner (der Finder löscht sie vorher einzeln) – dort steht der Ordner also bereits, hier nur entfernen.
static int stage_dir(const char *p, const char *r) {
    pthread_mutex_lock(&trash_lock);
    trash_paths();
    char dest[PATH_MAX], parent[PATH_MAX];
    snprintf(dest, sizeof dest, "%s%s", staging, p);
    snprintf(parent, sizeof parent, "%s", dest);
    char *slash = strrchr(parent, '/');
    if (slash) *slash = 0;
    struct stat st;
    int rc;
    if (stat(dest, &st) == 0 && S_ISDIR(st.st_mode)) rc = rmdir(r);
    else rc = mkdirs(parent, 0700) == 0 ? rename(r, dest) : -1;
    int err = errno;
    last_delete = time(NULL);
    pthread_mutex_unlock(&trash_lock);
    errno = err;
    return rc;
}

static int m_rmdir(const char *p) {
    REAL(p);
    if (from_finder()) TRY(stage_dir(p, r));
    TRY(rmdir(r));
}
static int m_symlink(const char *to, const char *p) { REAL(p); TRY(symlink(to, r)); }
static int m_rename(const char *from, const char *to) {
    char a[PATH_MAX], b[PATH_MAX];
    TRY(rename(real(from, a), real(to, b)));
}
static int m_chmod(const char *p, mode_t mode) { REAL(p); TRY(chmod(r, mode)); }
static int m_chown(const char *p, uid_t u, gid_t g) { REAL(p); TRY(lchown(r, u, g)); }
static int m_truncate(const char *p, off_t size) { REAL(p); TRY(truncate(r, size)); }
static int m_ftruncate(const char *p, off_t size, struct fuse_file_info *fi) { TRY(ftruncate(fi->fh, size)); }
static int m_utimens(const char *p, const struct timespec tv[2]) {
    REAL(p);
    TRY(utimensat(AT_FDCWD, r, tv, AT_SYMLINK_NOFOLLOW));
}
static int m_open(const char *p, struct fuse_file_info *fi) {
    REAL(p);
    int fd = open(r, fi->flags);
    if (fd == -1) return -errno;
    fi->fh = fd;
    return 0;
}
static int m_create(const char *p, mode_t mode, struct fuse_file_info *fi) {
    REAL(p);
    int fd = open(r, fi->flags, mode);
    if (fd == -1) return -errno;
    fi->fh = fd;
    return 0;
}
static int m_read(const char *p, char *buf, size_t size, off_t off, struct fuse_file_info *fi) {
    ssize_t n = pread(fi->fh, buf, size, off);
    return n == -1 ? -errno : (int)n;
}
static int m_write(const char *p, const char *buf, size_t size, off_t off, struct fuse_file_info *fi) {
    ssize_t n = pwrite(fi->fh, buf, size, off);
    return n == -1 ? -errno : (int)n;
}
static int m_statfs(const char *p, struct statvfs *st) { REAL(p); TRY(statvfs(r, st)); }
static int m_release(const char *p, struct fuse_file_info *fi) { close(fi->fh); return 0; }
static int m_fsync(const char *p, int datasync, struct fuse_file_info *fi) { TRY(fsync(fi->fh)); }
// Avid und Finder nutzen erweiterte Attribute (z. B. Resource Forks)
static int m_setxattr(const char *p, const char *name, const char *val, size_t size, int flags, uint32_t pos) {
    REAL(p);
    TRY(setxattr(r, name, val, size, pos, flags | XATTR_NOFOLLOW));
}
static int m_getxattr(const char *p, const char *name, char *val, size_t size, uint32_t pos) {
    REAL(p);
    ssize_t n = getxattr(r, name, val, size, pos, XATTR_NOFOLLOW);
    return n == -1 ? -errno : (int)n;
}
static int m_listxattr(const char *p, char *list, size_t size) {
    REAL(p);
    ssize_t n = listxattr(r, list, size, XATTR_NOFOLLOW);
    return n == -1 ? -errno : (int)n;
}
static int m_removexattr(const char *p, const char *name) { REAL(p); TRY(removexattr(r, name, XATTR_NOFOLLOW)); }

static struct fuse_operations ops = {
    .getattr = m_getattr, .access = m_access, .readlink = m_readlink, .readdir = m_readdir,
    .mkdir = m_mkdir, .unlink = m_unlink, .rmdir = m_rmdir, .symlink = m_symlink, .rename = m_rename,
    .chmod = m_chmod, .chown = m_chown, .truncate = m_truncate, .ftruncate = m_ftruncate,
    .utimens = m_utimens, .open = m_open, .create = m_create, .read = m_read, .write = m_write,
    .statfs = m_statfs, .release = m_release, .fsync = m_fsync,
    .setxattr = m_setxattr, .getxattr = m_getxattr, .listxattr = m_listxattr, .removexattr = m_removexattr,
    .init = m_init, .destroy = m_destroy,
};

int main(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "usage: mirror <source folder> <mount point> [-o volname=Name]\n");
        return 1;
    }
    if (!realpath(argv[1], root)) {
        fprintf(stderr, "source folder not found or not readable: %s\n", argv[1]);
        return 1;
    }
    // Quellordner aus den Argumenten nehmen, den Rest bekommt libfuse
    argv[1] = argv[0];
    return fuse_main(argc - 1, argv + 1, &ops, NULL);
}
