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
// Löschen ist endgültig: Netzlaufwerke haben keinen Papierkorb (ein Nachbau in den Papierkorb des Quelllaufwerks
// scheiterte an Ordnern auf NAS-Freigaben und wurde wieder entfernt).
static int m_unlink(const char *p) { REAL(p); TRY(unlink(r)); }
static int m_rmdir(const char *p) { REAL(p); TRY(rmdir(r)); }
static int m_symlink(const char *to, const char *p) { REAL(p); TRY(symlink(to, r)); }
static int m_rename(const char *from, const char *to) {
    char a[PATH_MAX], b[PATH_MAX];
    const char *ra = real(from, a), *rb = real(to, b);
    if (!ra || !rb) return -ENAMETOOLONG;
    TRY(rename(ra, rb));
}
// Verknüpfungen nie folgen: sonst änderte sich ihr Ziel, womöglich außerhalb des Workspace
static int m_chmod(const char *p, mode_t mode) { REAL(p); TRY(fchmodat(AT_FDCWD, r, mode, AT_SYMLINK_NOFOLLOW)); }
static int m_chown(const char *p, uid_t u, gid_t g) { REAL(p); TRY(lchown(r, u, g)); }
static int m_truncate(const char *p, off_t size) {
    REAL(p);
    int fd = open(r, O_WRONLY | O_NOFOLLOW);
    if (fd == -1) return -errno;
    int res = ftruncate(fd, size) == -1 ? -errno : 0;
    close(fd);
    return res;
}
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
static int m_setxattr(const char *p, const char *name, const char *val, size_t size, int flags, uint32_t pos) {
    REAL(p);
    TRY(setxattr(r, name, val, size, pos, (flags & ~(XATTR_NOSECURITY | XATTR_NODEFAULT)) | XATTR_NOFOLLOW));
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
