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

static char root[PATH_MAX];

// Pfad im Volume -> Pfad im Quellordner; NULL, wenn er zu lang wird.
// Nie gekürzt weitermachen: ein abgeschnittener Pfad zeigt auf ein anderes Objekt.
static const char *real(const char *path, char *buf) {
    int n = snprintf(buf, PATH_MAX, "%s%s", root, path);
    return n < 0 || n >= PATH_MAX ? NULL : buf;
}
#define REAL(p) char _b[PATH_MAX]; const char *r = real(p, _b); if (!r) return -ENAMETOOLONG
#define TRY(x) return (x) == -1 ? -errno : 0

// Keiner Verknüpfung im Quellordner folgen (*NOFOLLOW_ANY, auch nicht der letzten): sonst führte ein Ordner, den jemand
// nach dem Nachschlagen gegen eine Verknüpfung tauscht, mit den Rechten von Mountpoint (z. B. Ordner Dokumente) aus
// dem Quellordner hinaus. Verknüpfungen im Volume löst der Kernel selbst über readlink auf.
// Aufrufe ohne solche Option laufen über parent(): ihr Ordner wird ohne Verknüpfung geöffnet, der letzte Name relativ
// dazu benutzt. Für die Wurzel ("/") ist das der Quellordner selbst mit ".".
static int parent(const char *p, char *buf, const char **last) {
    if (!real(p, buf)) return -ENAMETOOLONG;
    char *s = strrchr(buf, '/');
    if (s[1]) { *last = s + 1; *s = 0; } else *last = ".";
    int fd = open(buf, O_SEARCH | O_NOFOLLOW_ANY | O_CLOEXEC);
    return fd == -1 ? -errno : fd;
}
#define AT(p) char _b[PATH_MAX]; const char *last; int dfd = parent(p, _b, &last); if (dfd < 0) return dfd
#define TRYAT(x) int res = (x) == -1 ? -errno : 0; close(dfd); return res

static int m_getattr(const char *p, struct stat *st) { REAL(p); TRY(fstatat(AT_FDCWD, r, st, AT_SYMLINK_NOFOLLOW_ANY)); }
static int m_access(const char *p, int mask) { REAL(p); TRY(faccessat(AT_FDCWD, r, mask, AT_SYMLINK_NOFOLLOW_ANY)); }
static int m_readlink(const char *p, char *buf, size_t size) {
    AT(p);
    ssize_t n = readlinkat(dfd, last, buf, size - 1);
    int res = n == -1 ? -errno : 0;
    close(dfd);
    if (n != -1) buf[n] = 0;
    return res;
}
static int m_readdir(const char *p, void *buf, fuse_fill_dir_t fill, off_t off, struct fuse_file_info *fi) {
    REAL(p);
    int fd = open(r, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC);
    if (fd == -1) return -errno;
    DIR *d = fdopendir(fd);
    if (!d) { int e = errno; close(fd); return -e; }
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
static int m_mkdir(const char *p, mode_t mode) { AT(p); TRYAT(mkdirat(dfd, last, mode)); }
// Löschen ist endgültig: Netzlaufwerke haben keinen Papierkorb (ein Nachbau in den Papierkorb des Quelllaufwerks
// scheiterte an Ordnern auf NAS-Freigaben und wurde wieder entfernt).
static int m_unlink(const char *p) { AT(p); TRYAT(unlinkat(dfd, last, 0)); }
static int m_rmdir(const char *p) { AT(p); TRYAT(unlinkat(dfd, last, AT_REMOVEDIR)); }
static int m_symlink(const char *to, const char *p) { AT(p); TRYAT(symlinkat(to, dfd, last)); }
static int m_rename(const char *from, const char *to) {
    char a[PATH_MAX], b[PATH_MAX];
    const char *ra = real(from, a), *rb = real(to, b);
    if (!ra || !rb) return -ENAMETOOLONG;
    TRY(renameatx_np(AT_FDCWD, ra, AT_FDCWD, rb, RENAME_NOFOLLOW_ANY));
}
// Verknüpfungen nie folgen: sonst änderte sich ihr Ziel, womöglich außerhalb des Workspace
static int m_chmod(const char *p, mode_t mode) { REAL(p); TRY(fchmodat(AT_FDCWD, r, mode, AT_SYMLINK_NOFOLLOW_ANY)); }
static int m_chown(const char *p, uid_t u, gid_t g) { AT(p); TRYAT(fchownat(dfd, last, u, g, AT_SYMLINK_NOFOLLOW)); }
static int m_truncate(const char *p, off_t size) {
    REAL(p);
    int fd = open(r, O_WRONLY | O_NOFOLLOW_ANY);
    if (fd == -1) return -errno;
    int res = ftruncate(fd, size) == -1 ? -errno : 0;
    close(fd);
    return res;
}
static int m_ftruncate(const char *p, off_t size, struct fuse_file_info *fi) { TRY(ftruncate(fi->fh, size)); }
static int m_utimens(const char *p, const struct timespec tv[2]) {
    AT(p);
    TRYAT(utimensat(dfd, last, tv, AT_SYMLINK_NOFOLLOW));
}
// O_NOFOLLOW zusammen mit O_NOFOLLOW_ANY lehnt macOS ab (EINVAL); O_NOFOLLOW_ANY deckt es mit ab.
static int m_open(const char *p, struct fuse_file_info *fi) {
    REAL(p);
    int fd = open(r, (fi->flags & ~O_NOFOLLOW) | O_NOFOLLOW_ANY);
    if (fd == -1) return -errno;
    fi->fh = fd;
    return 0;
}
static int m_create(const char *p, mode_t mode, struct fuse_file_info *fi) {
    REAL(p);
    int fd = open(r, (fi->flags & ~O_NOFOLLOW) | O_NOFOLLOW_ANY, mode);
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
// Bei jedem close() des Programms: Netzlaufwerke (SMB) melden Schreibfehler oft erst beim Schließen –
// close() auf einer Kopie des Handles reicht sie an Avid/Finder weiter, statt sie zu verschlucken.
static int m_flush(const char *p, struct fuse_file_info *fi) {
    int fd = dup(fi->fh);
    if (fd == -1) return -errno;
    TRY(close(fd));
}
static int m_release(const char *p, struct fuse_file_info *fi) { close(fi->fh); return 0; }
static int m_fsync(const char *p, int datasync, struct fuse_file_info *fi) { TRY(fsync(fi->fh)); }
// Avid und Finder nutzen erweiterte Attribute (z. B. Resource Forks)
// Der Finder setzt beim Kopieren XATTR_NOSECURITY/XATTR_NODEFAULT mit; die darf nur der Kernel benutzen,
// setxattr() lehnt sie mit EINVAL ab und der Finder bricht mit Fehler -50 ab – darum herausnehmen.
// XATTR_NOFOLLOW_ANY gibt es erst ab macOS 15 (darunter ohne Wirkung oder abgelehnt – darum nur dort gesetzt).
// shortcut: auf macOS 13/14 folgen xattr-Aufrufe einem getauschten Ordner im Pfad weiter (nur die letzte Stelle
// nicht); ein Weg über einen Deskriptor bräuchte Leserecht auf die Datei und bräche Avid/Finder bei
// Nur-Schreiben-Dateien. Entfernen, sobald macOS 15 das Minimum ist.
static int nofollow(void) {
    if (__builtin_available(macOS 15.0, *)) return XATTR_NOFOLLOW | XATTR_NOFOLLOW_ANY;
    return XATTR_NOFOLLOW;
}
static int m_setxattr(const char *p, const char *name, const char *val, size_t size, int flags, uint32_t pos) {
    REAL(p);
    TRY(setxattr(r, name, val, size, pos, (flags & ~(XATTR_NOSECURITY | XATTR_NODEFAULT)) | nofollow()));
}
static int m_getxattr(const char *p, const char *name, char *val, size_t size, uint32_t pos) {
    REAL(p);
    ssize_t n = getxattr(r, name, val, size, pos, nofollow());
    return n == -1 ? -errno : (int)n;
}
static int m_listxattr(const char *p, char *list, size_t size) {
    REAL(p);
    ssize_t n = listxattr(r, list, size, nofollow());
    return n == -1 ? -errno : (int)n;
}
static int m_removexattr(const char *p, const char *name) { REAL(p); TRY(removexattr(r, name, nofollow())); }

static struct fuse_operations ops = {
    .getattr = m_getattr, .access = m_access, .readlink = m_readlink, .readdir = m_readdir,
    .mkdir = m_mkdir, .unlink = m_unlink, .rmdir = m_rmdir, .symlink = m_symlink, .rename = m_rename,
    .chmod = m_chmod, .chown = m_chown, .truncate = m_truncate, .ftruncate = m_ftruncate,
    .utimens = m_utimens, .open = m_open, .create = m_create, .read = m_read, .write = m_write,
    .statfs = m_statfs, .flush = m_flush, .release = m_release, .fsync = m_fsync,
    .setxattr = m_setxattr, .getxattr = m_getxattr, .listxattr = m_listxattr, .removexattr = m_removexattr,
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
