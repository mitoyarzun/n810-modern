"""Backport the syscalls modern userspace needs into Nokia's 2.6.21 kernel.

Run from the root of the unpacked Diablo kernel source; see
tools/mk-kernel-2621-backport.sh.

WHY THIS INSTEAD OF MOVING TO 2.6.28. tools/probe-kernel.sh measured what the
Diablo kernel is missing, and it is five syscalls. Porting Nokia's board
support forward to 2.6.28 costs the DSP, MMC, DVFS and USB power management --
see APPS.md -- and still does not reach Go's floor of 3.2. Bringing five
syscalls back instead keeps every driver Nokia shipped.

WHAT THIS ADDS

  futex FUTEX_PRIVATE_FLAG   the blocker. Go uses FUTEX_WAIT_PRIVATE for
                             every mutex, so on a stock Diablo kernel no Go
                             program can take a lock.
  epoll_create1              epoll with EPOLL_CLOEXEC
  pipe2, dup3, accept4       the flag-taking forms of pipe, dup2 and accept

WHAT IT DOES NOT ADD

  eventfd/eventfd2           2.6.21 has no fs/anon_inodes.c, which the eventfd
                             implementation is built on. Porting it means
                             bringing anon_inodes back first. Go 1.19+ uses
                             eventfd for netpollBreak, so this is the next
                             piece of work if Go turns out to need it.
  getrandom                  arrived in 3.17; callers fall back to
                             /dev/urandom, which the device has.

HOW THE FUTEX CHANGE WORKS, AND WHY IT IS SOUND

2.6.22 added private futexes as an optimisation, not a new semantic. Its whole
mechanism is a pointer:

    int cmd = op & FUTEX_CMD_MASK;
    struct rw_semaphore *fshared = NULL;
    if (!(op & FUTEX_PRIVATE_FLAG))
            fshared = &current->mm->mmap_sem;

A private futex skips mmap_sem because it is known to be process-local. 2.6.21
always takes that semaphore, which is the conservative case and is correct for
private futexes too -- merely slower. So masking the flag off and running the
existing shared path gives correct behaviour.

The mask has to go in sys_futex(), not do_futex(). sys_futex compares the raw
op in three places to decide whether to copy the timeout and how to read val2:

    if (utime && (op == FUTEX_WAIT || op == FUTEX_LOCK_PI))
    if (op == FUTEX_WAIT)
    if (op == FUTEX_REQUEUE || op == FUTEX_CMP_REQUEUE)

Masking only in do_futex would leave those comparisons failing for a private
op, so a FUTEX_WAIT_PRIVATE with a timeout would wait forever instead. One
mask at the top of sys_futex covers every site.

CAVEAT ON THE FLAG-TAKING SYSCALLS

epoll_create1, pipe2, dup3 and accept4 are implemented here as wrappers: they
call the existing syscall and then apply the flags. That reintroduces exactly
the race the flag-taking forms were invented to close -- for a few
instructions the descriptor exists without O_CLOEXEC, so a concurrent fork+exec
could leak it. That is acceptable for making software run on a single-user
handheld; it is not a correct implementation, and anything relying on
close-on-exec atomicity for security should not trust it.
"""
import os
import sys

BACKPORT_C = r'''/*
 * Syscalls backported into the 2.6.21 Diablo kernel. See
 * tools/backport-syscalls.py in the n810-modern repository for the reasoning.
 *
 * These are wrappers over the existing syscalls. They reintroduce the
 * fd-visible-before-CLOEXEC race that the real implementations avoid; see the
 * caveat in that file.
 */
#include <linux/kernel.h>
#include <linux/syscalls.h>
#include <linux/file.h>
#include <linux/fs.h>
#include <linux/fcntl.h>
#include <linux/net.h>
#include <linux/socket.h>
#include <linux/errno.h>
#include <asm/uaccess.h>

extern void fastcall set_close_on_exec(unsigned int fd, int flag);

static void bp_apply_flags(int fd, int flags)
{
	if (flags & O_CLOEXEC)
		set_close_on_exec(fd, 1);
	if (flags & O_NONBLOCK) {
		struct file *f = fget(fd);
		if (f) {
			f->f_flags |= O_NONBLOCK;
			fput(f);
		}
	}
}

asmlinkage long sys_epoll_create1(int flags)
{
	int fd;

	if (flags & ~O_CLOEXEC)
		return -EINVAL;

	/* The size argument has been ignored since 2.6.8; any positive
	 * value does. */
	fd = sys_epoll_create(1);
	if (fd >= 0)
		bp_apply_flags(fd, flags & O_CLOEXEC);
	return fd;
}

asmlinkage long sys_dup3(unsigned int oldfd, unsigned int newfd, int flags)
{
	long ret;

	if (flags & ~O_CLOEXEC)
		return -EINVAL;
	if (oldfd == newfd)
		return -EINVAL;

	ret = sys_dup2(oldfd, newfd);
	if (ret >= 0)
		bp_apply_flags(newfd, flags & O_CLOEXEC);
	return ret;
}

asmlinkage long sys_pipe2(int __user *fildes, int flags)
{
	int fd[2];
	int error;

	if (flags & ~(O_CLOEXEC | O_NONBLOCK))
		return -EINVAL;

	error = do_pipe(fd);
	if (error)
		return error;

	bp_apply_flags(fd[0], flags);
	bp_apply_flags(fd[1], flags);

	if (copy_to_user(fildes, fd, sizeof(fd))) {
		sys_close(fd[0]);
		sys_close(fd[1]);
		return -EFAULT;
	}
	return 0;
}

asmlinkage long sys_accept4(int fd, struct sockaddr __user *upeer_sockaddr,
			    int __user *upeer_addrlen, int flags)
{
	long newfd;

	/* SOCK_CLOEXEC and SOCK_NONBLOCK are defined to equal O_CLOEXEC and
	 * O_NONBLOCK, so the same bits work here. */
	if (flags & ~(O_CLOEXEC | O_NONBLOCK))
		return -EINVAL;

	newfd = sys_accept(fd, upeer_sockaddr, upeer_addrlen);
	if (newfd >= 0)
		bp_apply_flags(newfd, flags);
	return newfd;
}
'''

# Syscall numbers are the canonical ARM ones. Everything we do not implement
# stays sys_ni_syscall so the numbering does not drift -- userspace calls these
# by number, so a shifted table would be worse than a missing syscall.
CALLS = """/* 348 */	CALL(sys_ni_syscall)		/* utimensat */
		CALL(sys_ni_syscall)		/* signalfd */
		CALL(sys_ni_syscall)		/* timerfd_create */
		CALL(sys_ni_syscall)		/* eventfd (needs anon_inodes) */
		CALL(sys_ni_syscall)		/* fallocate */
/* 353 */	CALL(sys_ni_syscall)		/* timerfd_settime */
		CALL(sys_ni_syscall)		/* timerfd_gettime */
		CALL(sys_ni_syscall)		/* signalfd4 */
		CALL(sys_ni_syscall)		/* eventfd2 (needs anon_inodes) */
/* 357 */	CALL(sys_epoll_create1)
		CALL(sys_dup3)
		CALL(sys_pipe2)
		CALL(sys_ni_syscall)		/* inotify_init1 */
/* 361 */	CALL(sys_ni_syscall)		/* preadv */
		CALL(sys_ni_syscall)		/* pwritev */
		CALL(sys_ni_syscall)		/* rt_tgsigqueueinfo */
		CALL(sys_ni_syscall)		/* perf_event_open */
		CALL(sys_ni_syscall)		/* recvmmsg */
/* 366 */	CALL(sys_accept4)
"""

UNISTD = """#define __NR_epoll_create1		(__NR_SYSCALL_BASE+357)
#define __NR_dup3			(__NR_SYSCALL_BASE+358)
#define __NR_pipe2			(__NR_SYSCALL_BASE+359)
#define __NR_accept4			(__NR_SYSCALL_BASE+366)
"""

FUTEX_H = """
/* Backported from 2.6.22. Private futexes are an optimisation: they let the
 * kernel skip mmap_sem because the futex is known to be process-local. This
 * kernel always takes it, which is correct for both cases. */
#define FUTEX_PRIVATE_FLAG	128
#define FUTEX_CMD_MASK		~FUTEX_PRIVATE_FLAG

#define FUTEX_WAIT_PRIVATE	(FUTEX_WAIT | FUTEX_PRIVATE_FLAG)
#define FUTEX_WAKE_PRIVATE	(FUTEX_WAKE | FUTEX_PRIVATE_FLAG)
#define FUTEX_REQUEUE_PRIVATE	(FUTEX_REQUEUE | FUTEX_PRIVATE_FLAG)
#define FUTEX_CMP_REQUEUE_PRIVATE (FUTEX_CMP_REQUEUE | FUTEX_PRIVATE_FLAG)
#define FUTEX_WAKE_OP_PRIVATE	(FUTEX_WAKE_OP | FUTEX_PRIVATE_FLAG)
#define FUTEX_LOCK_PI_PRIVATE	(FUTEX_LOCK_PI | FUTEX_PRIVATE_FLAG)
#define FUTEX_UNLOCK_PI_PRIVATE	(FUTEX_UNLOCK_PI | FUTEX_PRIVATE_FLAG)
#define FUTEX_TRYLOCK_PI_PRIVATE (FUTEX_TRYLOCK_PI | FUTEX_PRIVATE_FLAG)
"""


def edit(path, old, new, what, marker, count=1):
    """Apply one edit. `marker` is a string that appears ONLY after the edit.

    Deriving the marker from `new` does not work: several of these edits keep
    their anchor line, so the first line of the replacement is already in the
    file and the edit gets skipped on a clean tree. That failure is silent --
    the build succeeds and the syscall is simply absent.
    """
    with open(path, encoding='latin-1') as fh:
        s = fh.read()
    if marker in s:
        print('    SKIP %-34s (already applied)' % what)
        return True
    if old not in s:
        print('    FAIL %-34s (anchor not found)' % what)
        return False
    with open(path, 'w', encoding='latin-1') as fh:
        fh.write(s.replace(old, new, count))
    print('    %s' % what)
    return True


def main():
    ok = True

    # 1. The futex flag definitions.
    ok &= edit('include/linux/futex.h',
               '#define FUTEX_WAIT\t\t0',
               '#define FUTEX_WAIT\t\t0' + FUTEX_H,
               'futex.h: private-futex defines', 'FUTEX_PRIVATE_FLAG')

    # 2. One mask, at the top of sys_futex, before any comparison of op.
    ok &= edit('kernel/futex.c',
               """\tstruct timespec t;
\tunsigned long timeout = MAX_SCHEDULE_TIMEOUT;
\tu32 val2 = 0;
""",
               """\tstruct timespec t;
\tunsigned long timeout = MAX_SCHEDULE_TIMEOUT;
\tu32 val2 = 0;

\t/* Accept the private-futex flag by running the shared path, which is
\t * correct and merely skips the optimisation. This must happen before
\t * the comparisons below, which test the raw op. */
\top &= FUTEX_CMD_MASK;
""",
               'futex.c: mask FUTEX_PRIVATE_FLAG', 'op &= FUTEX_CMD_MASK')

    # 3. O_CLOEXEC. It arrived in 2.6.23; the flag-taking syscalls need it,
    #    and userspace expects the same value (02000000).
    ok &= edit('include/asm-arm/fcntl.h',
               '#define O_LARGEFILE\t0400000\n',
               '#define O_LARGEFILE\t0400000\n'
               '#define O_CLOEXEC\t02000000\t/* set close_on_exec */\n',
               'fcntl.h: O_CLOEXEC', 'O_CLOEXEC')

    # 4. The new syscalls.
    if os.path.exists('fs/backport.c'):
        print('    SKIP %-34s (already present)' % 'fs/backport.c')
    else:
        with open('fs/backport.c', 'w', encoding='latin-1') as fh:
            fh.write(BACKPORT_C)
        print('    fs/backport.c: epoll_create1, dup3, pipe2, accept4')

    ok &= edit('fs/Makefile',
               'obj-y :=\topen.o read_write.o file_table.o super.o \\',
               'obj-y :=\tbackport.o open.o read_write.o file_table.o super.o \\',
               'fs/Makefile: build backport.o', 'backport.o')

    # 5. The syscall table. Numbers must match ARM's canonical assignments.
    ok &= edit('arch/arm/kernel/calls.S',
               '\t\tCALL(sys_kexec_load)\n',
               '\t\tCALL(sys_kexec_load)\n' + CALLS,
               'calls.S: entries 348-366', 'sys_epoll_create1')

    # 6. The __NR_ numbers userspace calls them by.
    ok &= edit('include/asm-arm/unistd.h',
               '#define __NR_kexec_load',
               UNISTD + '#define __NR_kexec_load',
               'unistd.h: __NR_ numbers', '__NR_epoll_create1')

    if not ok:
        sys.exit(1)


if __name__ == '__main__':
    main()
