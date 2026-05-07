/*
 * Create classic /dev/binder, /dev/hwbinder, /dev/vndbinder on hosts where
 * CONFIG_ANDROID_BINDER_DEVICES is empty (binderfs-only), e.g. Ubuntu 24.04
 * generic cloud kernels. Run as root once after modprobe binder_linux.
 *
 * Build: gcc -O2 -Wall -o binderfs-init binderfs-init.c
 * Requires: linux-libc-dev (for <linux/android/binderfs.h>) on Debian/Ubuntu.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include <linux/android/binderfs.h>

static int add_device(int ctl_fd, const char *name) {
	struct binderfs_device dev;
	memset(&dev, 0, sizeof(dev));
	if (strlen(name) > BINDERFS_MAX_NAME) {
		fprintf(stderr, "name too long: %s\n", name);
		return -1;
	}
	strncpy(dev.name, name, sizeof(dev.name) - 1);
	if (ioctl(ctl_fd, BINDER_CTL_ADD, &dev) != 0) {
		if (errno == EEXIST) {
			fprintf(stderr, "binderfs device '%s' already exists (ok)\n", name);
			return 0;
		}
		perror("BINDER_CTL_ADD");
		return -1;
	}
	return 0;
}

static int symlink_force(const char *target, const char *linkpath) {
	unlink(linkpath);
	if (symlink(target, linkpath) != 0) {
		perror(linkpath);
		return -1;
	}
	return 0;
}

int main(void) {
	const char *mnt = "/dev/binderfs";
	const char *ctl_path = "/dev/binderfs/binder-control";

	if (mkdir(mnt, 0755) != 0 && errno != EEXIST) {
		perror("mkdir /dev/binderfs");
		return 1;
	}

	if (mount("binder", mnt, "binder", 0, NULL) != 0) {
		if (errno != EBUSY) {
			perror("mount binderfs");
			return 1;
		}
	}

	int ctl = open(ctl_path, O_RDONLY | O_CLOEXEC);
	if (ctl < 0) {
		perror(ctl_path);
		return 1;
	}

	const char *names[] = {"binder", "hwbinder", "vndbinder"};
	for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
		if (add_device(ctl, names[i]) != 0) {
			close(ctl);
			return 1;
		}
	}
	close(ctl);

	char src[512];
	for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
		snprintf(src, sizeof(src), "%s/%s", mnt, names[i]);
		char dst[64];
		snprintf(dst, sizeof(dst), "/dev/%s", names[i]);
		if (symlink_force(src, dst) != 0) {
			return 1;
		}
	}

	fprintf(stderr, "binderfs ok: /dev/{binder,hwbinder,vndbinder} -> %s/*\n", mnt);
	return 0;
}
