# These variables are specifically meant to be overridable via the make
# command-line.
# ?= doesn't work for CC and AR because make has a default value for them.
ifeq ($(origin CC), default)
CC := clang
endif
NM ?= $(patsubst %clang,%llvm-nm,$(filter-out ccache sccache,$(CC)))
ifeq ($(origin AR), default)
AR = $(patsubst %clang,%llvm-ar,$(filter-out ccache sccache,$(CC)))
endif
EXTRA_CFLAGS ?= -O2 -DNDEBUG
# The directory where we build the sysroot.
SYSROOT ?= $(CURDIR)/sysroot
# A directory to install to for "make install".
INSTALL_DIR ?= /usr/local
# single or posix; note that pthread support is still a work-in-progress.
THREAD_MODEL ?= single
# p1 or p2; the latter is not (yet) compatible with multithreading
WASI_SNAPSHOT ?= p1
# dlmalloc or none
MALLOC_IMPL ?= dlmalloc
# yes or no
BUILD_LIBC_TOP_HALF ?= yes
# yes or no
BUILD_LIBSETJMP ?= yes
# The directory where we will store intermediate artifacts.
OBJDIR ?= build/$(TARGET_TRIPLE)

# LTO; no, full, or thin
# Note: thin LTO here is just for experimentation. It has known issues:
# - https://github.com/llvm/llvm-project/issues/91700
# - https://github.com/llvm/llvm-project/issues/91711
LTO ?= no
ifneq ($(LTO),no)
CLANG_VERSION ?= $(shell ${CC} -dumpversion)
override OBJDIR := $(OBJDIR)/llvm-lto/$(CLANG_VERSION)
endif

# When the length is no larger than this threshold, we consider the
# overhead of bulk memory opcodes to outweigh the performance benefit,
# and fall back to the original musl implementation. See
# https://github.com/WebAssembly/wasi-libc/pull/263 for relevant
# discussion
BULK_MEMORY_THRESHOLD ?= 32

# Variables from this point on are not meant to be overridable via the
# make command-line.

# Set the default WASI target triple.
TARGET_TRIPLE ?= wasm32-wasi

# Threaded version necessitates a different target, as objects from different
# targets can't be mixed together while linking.
ifeq ($(THREAD_MODEL), posix)
TARGET_TRIPLE ?= wasm32-wasi-threads
endif

ifeq ($(WASI_SNAPSHOT), p2)
TARGET_TRIPLE ?= wasm32-wasip2
endif

# These artifacts are "stamps" that we use to mark that some task (e.g., copying
# files) has been completed.
INCLUDE_DIRS := $(OBJDIR)/copy-include-headers.stamp

# These variables describe the locations of various files and directories in
# the source tree.
DLMALLOC_DIR = dlmalloc
DLMALLOC_SRC_DIR = $(DLMALLOC_DIR)/src
DLMALLOC_SOURCES = $(DLMALLOC_SRC_DIR)/dlmalloc.c
DLMALLOC_INC = $(DLMALLOC_DIR)/include
EMMALLOC_DIR = emmalloc
EMMALLOC_SOURCES = $(EMMALLOC_DIR)/emmalloc.c
STUB_PTHREADS_DIR = stub-pthreads
LIBC_BOTTOM_HALF_DIR = libc-bottom-half
LIBC_BOTTOM_HALF_CLOUDLIBC_SRC = $(LIBC_BOTTOM_HALF_DIR)/cloudlibc/src
LIBC_BOTTOM_HALF_CLOUDLIBC_SRC_INC = $(LIBC_BOTTOM_HALF_CLOUDLIBC_SRC)/include
LIBC_BOTTOM_HALF_HEADERS_PUBLIC = $(LIBC_BOTTOM_HALF_DIR)/headers/public
LIBC_BOTTOM_HALF_HEADERS_PRIVATE = $(LIBC_BOTTOM_HALF_DIR)/headers/private
LIBC_BOTTOM_HALF_SOURCES = $(LIBC_BOTTOM_HALF_DIR)/sources
LIBC_BOTTOM_HALF_ALL_SOURCES = \
    $(sort \
    $(shell find $(LIBC_BOTTOM_HALF_CLOUDLIBC_SRC) -name \*.c) \
    $(shell find $(LIBC_BOTTOM_HALF_SOURCES) -name \*.c))

ifeq ($(WASI_SNAPSHOT), p1)
# Omit source files not relevant to WASIp1.  As we introduce files
# supporting `wasi-sockets` for `wasm32-wasip2`, we'll add those files to
# this list.
LIBC_BOTTOM_HALF_OMIT_SOURCES := \
	$(LIBC_BOTTOM_HALF_SOURCES)/wasip2.c \
	$(LIBC_BOTTOM_HALF_SOURCES)/descriptor_table.c \
	$(LIBC_BOTTOM_HALF_SOURCES)/connect.c \
	$(LIBC_BOTTOM_HALF_SOURCES)/socket.c \
	$(LIBC_BOTTOM_HALF_SOURCES)/send.c \
	$(LIBC_BOTTOM_HALF_SOURCES)/recv.c \
	$(LIBC_BOTTOM_HALF_SOURCES)/sockets_utils.c \
	$(LIBC_BOTTOM_HALF_SOURCES)/bind.c \
	$(LIBC_BOTTOM_HALF_SOURCES)/listen.c \
	$(LIBC_BOTTOM_HALF_SOURCES)/accept-wasip2.c \
	$(LIBC_BOTTOM_HALF_SOURCES)/shutdown.c \
	$(LIBC_BOTTOM_HALF_SOURCES)/sockopt.c \
	$(LIBC_BOTTOM_HALF_SOURCES)/poll-wasip2.c \
	$(LIBC_BOTTOM_HALF_SOURCES)/getsockpeername.c \
	$(LIBC_BOTTOM_HALF_SOURCES)/netdb.c
LIBC_BOTTOM_HALF_ALL_SOURCES := $(filter-out $(LIBC_BOTTOM_HALF_OMIT_SOURCES),$(LIBC_BOTTOM_HALF_ALL_SOURCES))
# Omit p2-specific headers from include-all.c test.
# for exception-handling.
INCLUDE_ALL_CLAUSES := -not -name wasip2.h -not -name descriptor_table.h
endif

ifeq ($(WASI_SNAPSHOT), p2)
# Omit source files not relevant to WASIp2.
LIBC_BOTTOM_HALF_OMIT_SOURCES := \
	$(LIBC_BOTTOM_HALF_CLOUDLIBC_SRC)/libc/sys/socket/send.c \
	$(LIBC_BOTTOM_HALF_CLOUDLIBC_SRC)/libc/sys/socket/recv.c \
	$(LIBC_BOTTOM_HALF_CLOUDLIBC_SRC)/libc/sys/socket/shutdown.c \
	$(LIBC_BOTTOM_HALF_CLOUDLIBC_SRC)/libc/sys/socket/getsockopt.c \
	$(LIBC_BOTTOM_HALF_SOURCES)/accept-wasip1.c
LIBC_BOTTOM_HALF_ALL_SOURCES := $(filter-out $(LIBC_BOTTOM_HALF_OMIT_SOURCES),$(LIBC_BOTTOM_HALF_ALL_SOURCES))
endif

# FIXME(https://reviews.llvm.org/D85567) - due to a bug in LLD the weak
# references to a function defined in `chdir.c` only work if `chdir.c` is at the
# end of the archive, but once that LLD review lands and propagates into LLVM
# then we don't have to do this.
LIBC_BOTTOM_HALF_ALL_SOURCES := $(filter-out $(LIBC_BOTTOM_HALF_SOURCES)/chdir.c,$(LIBC_BOTTOM_HALF_ALL_SOURCES))
LIBC_BOTTOM_HALF_ALL_SOURCES := $(LIBC_BOTTOM_HALF_ALL_SOURCES) $(LIBC_BOTTOM_HALF_SOURCES)/chdir.c

LIBWASI_EMULATED_MMAN_SOURCES = \
    $(sort $(shell find $(LIBC_BOTTOM_HALF_DIR)/mman -name \*.c))
LIBWASI_EMULATED_PROCESS_CLOCKS_SOURCES = \
    $(sort $(shell find $(LIBC_BOTTOM_HALF_DIR)/clocks -name \*.c))
LIBWASI_EMULATED_GETPID_SOURCES = \
    $(sort $(shell find $(LIBC_BOTTOM_HALF_DIR)/getpid -name \*.c))
LIBWASI_EMULATED_SIGNAL_SOURCES = \
    $(sort $(shell find $(LIBC_BOTTOM_HALF_DIR)/signal -name \*.c))
LIBWASI_EMULATED_SIGNAL_MUSL_SOURCES = \
    $(LIBC_TOP_HALF_MUSL_SRC_DIR)/signal/psignal.c \
    $(LIBC_TOP_HALF_MUSL_SRC_DIR)/string/strsignal.c
LIBWASI_EMULATED_PTHREAD_SOURCES = \
    $(STUB_PTHREADS_DIR)/stub-pthreads-emulated.c
LIBDL_SOURCES = $(LIBC_TOP_HALF_MUSL_SRC_DIR)/misc/dl.c
LIBSETJMP_SOURCES = $(LIBC_TOP_HALF_MUSL_SRC_DIR)/setjmp/wasm32/rt.c
LIBC_BOTTOM_HALF_CRT_SOURCES = $(wildcard $(LIBC_BOTTOM_HALF_DIR)/crt/*.c)
LIBC_TOP_HALF_DIR = libc-top-half
LIBC_TOP_HALF_MUSL_DIR = $(LIBC_TOP_HALF_DIR)/musl
LIBC_TOP_HALF_MUSL_SRC_DIR = $(LIBC_TOP_HALF_MUSL_DIR)/src
LIBC_TOP_HALF_MUSL_INC = $(LIBC_TOP_HALF_MUSL_DIR)/include
LIBC_TOP_HALF_MUSL_SOURCES = \
    $(addprefix $(LIBC_TOP_HALF_MUSL_SRC_DIR)/, \
        misc/a64l.c \
        misc/basename.c \
        misc/dirname.c \
        misc/ffs.c \
        misc/ffsl.c \
        misc/ffsll.c \
        misc/fmtmsg.c \
        misc/getdomainname.c \
        misc/gethostid.c \
        misc/getopt.c \
        misc/getopt_long.c \
        misc/getsubopt.c \
        misc/realpath.c \
        misc/uname.c \
        misc/nftw.c \
        errno/strerror.c \
        network/htonl.c \
        network/htons.c \
        network/ntohl.c \
        network/ntohs.c \
        network/inet_ntop.c \
        network/inet_pton.c \
        network/inet_aton.c \
        network/in6addr_any.c \
        network/in6addr_loopback.c \
        fenv/fenv.c \
        fenv/fesetround.c \
        fenv/feupdateenv.c \
        fenv/fesetexceptflag.c \
        fenv/fegetexceptflag.c \
        fenv/feholdexcept.c \
        exit/exit.c \
        exit/atexit.c \
        exit/assert.c \
        exit/quick_exit.c \
        exit/at_quick_exit.c \
        time/strftime.c \
        time/asctime.c \
        time/asctime_r.c \
        time/ctime.c \
        time/ctime_r.c \
        time/wcsftime.c \
        time/strptime.c \
        time/difftime.c \
        time/timegm.c \
        time/ftime.c \
        time/gmtime.c \
        time/gmtime_r.c \
        time/timespec_get.c \
        time/getdate.c \
        time/localtime.c \
        time/localtime_r.c \
        time/mktime.c \
        time/__tm_to_secs.c \
        time/__month_to_secs.c \
        time/__secs_to_tm.c \
        time/__year_to_secs.c \
        time/__tz.c \
        fcntl/creat.c \
        dirent/alphasort.c \
        dirent/versionsort.c \
        env/__stack_chk_fail.c \
        env/clearenv.c \
        env/getenv.c \
        env/putenv.c \
        env/setenv.c \
        env/unsetenv.c \
        unistd/posix_close.c \
        stat/futimesat.c \
        legacy/getpagesize.c \
        thread/thrd_sleep.c \
    ) \
    $(filter-out %/procfdname.c %/syscall.c %/syscall_ret.c %/vdso.c %/version.c %/emulate_wait4.c, \
                 $(wildcard $(LIBC_TOP_HALF_MUSL_SRC_DIR)/internal/*.c)) \
    $(filter-out %/flockfile.c %/funlockfile.c %/__lockfile.c %/ftrylockfile.c \
                 %/rename.c \
                 %/tmpnam.c %/tmpfile.c %/tempnam.c \
                 %/popen.c %/pclose.c \
                 %/remove.c \
                 %/gets.c, \
                 $(wildcard $(LIBC_TOP_HALF_MUSL_SRC_DIR)/stdio/*.c)) \
    $(filter-out %/strsignal.c, \
                 $(wildcard $(LIBC_TOP_HALF_MUSL_SRC_DIR)/string/*.c)) \
    $(filter-out %/dcngettext.c %/textdomain.c %/bind_textdomain_codeset.c, \
                 $(wildcard $(LIBC_TOP_HALF_MUSL_SRC_DIR)/locale/*.c)) \
    $(wildcard $(LIBC_TOP_HALF_MUSL_SRC_DIR)/stdlib/*.c) \
    $(wildcard $(LIBC_TOP_HALF_MUSL_SRC_DIR)/search/*.c) \
    $(wildcard $(LIBC_TOP_HALF_MUSL_SRC_DIR)/multibyte/*.c) \
    $(wildcard $(LIBC_TOP_HALF_MUSL_SRC_DIR)/regex/*.c) \
    $(wildcard $(LIBC_TOP_HALF_MUSL_SRC_DIR)/prng/*.c) \
    $(wildcard $(LIBC_TOP_HALF_MUSL_SRC_DIR)/conf/*.c) \
    $(wildcard $(LIBC_TOP_HALF_MUSL_SRC_DIR)/ctype/*.c) \
    $(filter-out %/__signbit.c %/__signbitf.c %/__signbitl.c \
                 %/__fpclassify.c %/__fpclassifyf.c %/__fpclassifyl.c \
                 %/ceilf.c %/ceil.c \
                 %/floorf.c %/floor.c \
                 %/truncf.c %/trunc.c \
                 %/rintf.c %/rint.c \
                 %/nearbyintf.c %/nearbyint.c \
                 %/sqrtf.c %/sqrt.c \
                 %/fabsf.c %/fabs.c \
                 %/copysignf.c %/copysign.c \
                 %/fminf.c %/fmaxf.c \
                 %/fmin.c %/fmax.c, \
                 $(wildcard $(LIBC_TOP_HALF_MUSL_SRC_DIR)/math/*.c)) \
    $(filter-out %/crealf.c %/creal.c %creall.c \
                 %/cimagf.c %/cimag.c %cimagl.c, \
                 $(wildcard $(LIBC_TOP_HALF_MUSL_SRC_DIR)/complex/*.c)) \
    $(wildcard $(LIBC_TOP_HALF_MUSL_SRC_DIR)/crypt/*.c)

LIBC_NONLTO_SOURCES = \
    $(addprefix $(LIBC_TOP_HALF_MUSL_SRC_DIR)/, \
        exit/atexit.c \
        setjmp/wasm32/rt.c \
    )

ifeq ($(WASI_SNAPSHOT), p2)
LIBC_TOP_HALF_MUSL_SOURCES += \
    $(addprefix $(LIBC_TOP_HALF_MUSL_SRC_DIR)/, \
       network/gai_strerror.c \
    )
endif

# pthreads functions (possibly stub) for either thread model
LIBC_TOP_HALF_MUSL_SOURCES += \
    $(addprefix $(LIBC_TOP_HALF_MUSL_SRC_DIR)/, \
        thread/default_attr.c \
        thread/pthread_attr_destroy.c \
        thread/pthread_attr_get.c \
        thread/pthread_attr_init.c \
        thread/pthread_attr_setdetachstate.c \
        thread/pthread_attr_setguardsize.c \
        thread/pthread_attr_setschedparam.c \
        thread/pthread_attr_setstack.c \
        thread/pthread_attr_setstacksize.c \
        thread/pthread_barrierattr_destroy.c \
        thread/pthread_barrierattr_init.c \
        thread/pthread_barrierattr_setpshared.c \
        thread/pthread_cancel.c \
        thread/pthread_cleanup_push.c \
        thread/pthread_condattr_destroy.c \
        thread/pthread_condattr_init.c \
        thread/pthread_condattr_setclock.c \
        thread/pthread_condattr_setpshared.c \
        thread/pthread_equal.c \
        thread/pthread_getspecific.c \
        thread/pthread_key_create.c \
        thread/pthread_mutex_destroy.c \
        thread/pthread_mutex_init.c \
        thread/pthread_mutexattr_destroy.c \
        thread/pthread_mutexattr_init.c \
        thread/pthread_mutexattr_setprotocol.c \
        thread/pthread_mutexattr_setpshared.c \
        thread/pthread_mutexattr_setrobust.c \
        thread/pthread_mutexattr_settype.c \
        thread/pthread_rwlock_destroy.c \
        thread/pthread_rwlock_init.c \
        thread/pthread_rwlockattr_destroy.c \
        thread/pthread_rwlockattr_init.c \
        thread/pthread_rwlockattr_setpshared.c \
        thread/pthread_self.c \
        thread/pthread_setcancelstate.c \
        thread/pthread_setcanceltype.c \
        thread/pthread_setspecific.c \
        thread/pthread_spin_destroy.c \
        thread/pthread_spin_init.c \
        thread/pthread_testcancel.c \
    )
ifeq ($(THREAD_MODEL), posix)
# pthreads functions needed for actual thread support
LIBC_TOP_HALF_MUSL_SOURCES += \
    $(addprefix $(LIBC_TOP_HALF_MUSL_SRC_DIR)/, \
        env/__init_tls.c \
        stdio/__lockfile.c \
        stdio/flockfile.c \
        stdio/ftrylockfile.c \
        stdio/funlockfile.c \
        thread/__lock.c \
        thread/__wait.c \
        thread/__timedwait.c \
        thread/pthread_barrier_destroy.c \
        thread/pthread_barrier_init.c \
        thread/pthread_barrier_wait.c \
        thread/pthread_cond_broadcast.c \
        thread/pthread_cond_destroy.c \
        thread/pthread_cond_init.c \
        thread/pthread_cond_signal.c \
        thread/pthread_cond_timedwait.c \
        thread/pthread_cond_wait.c \
        thread/pthread_create.c \
        thread/pthread_detach.c \
        thread/pthread_getattr_np.c \
        thread/pthread_join.c \
        thread/pthread_mutex_consistent.c \
        thread/pthread_mutex_getprioceiling.c \
        thread/pthread_mutex_lock.c \
        thread/pthread_mutex_timedlock.c \
        thread/pthread_mutex_trylock.c \
        thread/pthread_mutex_unlock.c \
        thread/pthread_once.c \
        thread/pthread_rwlock_rdlock.c \
        thread/pthread_rwlock_timedrdlock.c \
        thread/pthread_rwlock_timedwrlock.c \
        thread/pthread_rwlock_tryrdlock.c \
        thread/pthread_rwlock_trywrlock.c \
        thread/pthread_rwlock_unlock.c \
        thread/pthread_rwlock_wrlock.c \
        thread/pthread_spin_lock.c \
        thread/pthread_spin_trylock.c \
        thread/pthread_spin_unlock.c \
        thread/sem_destroy.c \
        thread/sem_getvalue.c \
        thread/sem_init.c \
        thread/sem_post.c \
        thread/sem_timedwait.c \
        thread/sem_trywait.c \
        thread/sem_wait.c \
        thread/wasm32/wasi_thread_start.s \
        thread/wasm32/__wasilibc_busywait.c \
    )
endif
ifeq ($(THREAD_MODEL), single)
# pthreads stubs for single-threaded environment
LIBC_TOP_HALF_MUSL_SOURCES += \
    $(STUB_PTHREADS_DIR)/barrier.c \
    $(STUB_PTHREADS_DIR)/condvar.c \
    $(STUB_PTHREADS_DIR)/mutex.c \
    $(STUB_PTHREADS_DIR)/rwlock.c \
    $(STUB_PTHREADS_DIR)/spinlock.c \
    $(STUB_PTHREADS_DIR)/stub-pthreads-good.c
endif

MUSL_PRINTSCAN_SOURCES = \
    $(LIBC_TOP_HALF_MUSL_SRC_DIR)/internal/floatscan.c \
    $(LIBC_TOP_HALF_MUSL_SRC_DIR)/stdio/vfprintf.c \
    $(LIBC_TOP_HALF_MUSL_SRC_DIR)/stdio/vfwprintf.c \
    $(LIBC_TOP_HALF_MUSL_SRC_DIR)/stdio/vfscanf.c \
    $(LIBC_TOP_HALF_MUSL_SRC_DIR)/stdlib/strtod.c \
    $(LIBC_TOP_HALF_MUSL_SRC_DIR)/stdlib/wcstod.c
BULK_MEMORY_SOURCES =
LIBC_TOP_HALF_HEADERS_PRIVATE = $(LIBC_TOP_HALF_DIR)/headers/private
LIBC_TOP_HALF_SOURCES = $(LIBC_TOP_HALF_DIR)/sources
LIBC_TOP_HALF_ALL_SOURCES = \
    $(LIBC_TOP_HALF_MUSL_SOURCES) \
    $(sort $(shell find $(LIBC_TOP_HALF_SOURCES) -name \*.[cs]))

FTS_SRC_DIR = fts
MUSL_FTS_SRC_DIR = $(FTS_SRC_DIR)/musl-fts
FTS_SOURCES = $(MUSL_FTS_SRC_DIR)/fts.c

# Add any extra flags
CFLAGS = $(EXTRA_CFLAGS)
# Set the target.
CFLAGS += --target=$(TARGET_TRIPLE)
ASMFLAGS += --target=$(TARGET_TRIPLE)
# WebAssembly floating-point match doesn't trap.
# TODO: Add -fno-signaling-nans when the compiler supports it.
CFLAGS += -fno-trapping-math
# Add all warnings, but disable a few which occur in third-party code.
CFLAGS += -Wall -Wextra -Werror \
  -Wno-null-pointer-arithmetic \
  -Wno-unused-parameter \
  -Wno-sign-compare \
  -Wno-unused-variable \
  -Wno-unused-function \
  -Wno-ignored-attributes \
  -Wno-missing-braces \
  -Wno-ignored-pragmas \
  -Wno-unused-but-set-variable \
  -Wno-unknown-warning-option \
  -Wno-unterminated-string-initialization

# Configure support for threads.
ifeq ($(THREAD_MODEL), single)
CFLAGS += -mthread-model single
endif
ifeq ($(THREAD_MODEL), posix)
# Specify the tls-model until LLVM 15 is released (which should contain
# https://reviews.llvm.org/D130053).
CFLAGS += -mthread-model posix -pthread -ftls-model=local-exec
ASMFLAGS += -matomics
endif

# Include cloudlib's directory to access the structure definition of clockid_t
CFLAGS += -I$(LIBC_BOTTOM_HALF_CLOUDLIBC_SRC)

ifneq ($(LTO),no)
ifeq ($(LTO),full)
CFLAGS += -flto=full
else
ifeq ($(LTO),thin)
CFLAGS += -flto=thin
else
$(error unknown LTO value: $(LTO))
endif
endif
endif

ifeq ($(WASI_SNAPSHOT), p2)
CFLAGS += -D__wasilibc_use_wasip2
endif

# Expose the public headers to the implementation. We use `-isystem` for
# purpose for two reasons:
#
# 1. It only does `<...>` not `"...."` lookup. We are making a libc,
#    which is a system library, so all public headers should be
#    accessible via `<...>` and never also need `"..."`. `-isystem` main
#    purpose is to only effect `<...>` lookup.
#
# 2. The `-I` for private headers added for specific C files below
#    should come earlier in the search path, so they can "override"
#    and/or `#include_next` the public headers. `-isystem` (like
#    `-idirafter`) comes later in the search path than `-I`.
CFLAGS += -isystem "$(SYSROOT_INC)"

# These variables describe the locations of various files and directories in
# the build tree.
objs = $(patsubst %.c,$(OBJDIR)/%.o,$(1))
asmobjs = $(patsubst %.s,$(OBJDIR)/%.o,$(1))
DLMALLOC_OBJS = $(call objs,$(DLMALLOC_SOURCES))
EMMALLOC_OBJS = $(call objs,$(EMMALLOC_SOURCES))
LIBC_BOTTOM_HALF_ALL_OBJS = $(call objs,$(LIBC_BOTTOM_HALF_ALL_SOURCES))
LIBC_TOP_HALF_ALL_OBJS = $(call asmobjs,$(call objs,$(LIBC_TOP_HALF_ALL_SOURCES)))
FTS_OBJS = $(call objs,$(FTS_SOURCES))
ifeq ($(WASI_SNAPSHOT), p2)
LIBC_OBJS += $(OBJDIR)/wasip2_component_type.o
endif
ifeq ($(MALLOC_IMPL),dlmalloc)
LIBC_OBJS += $(DLMALLOC_OBJS)
else ifeq ($(MALLOC_IMPL),emmalloc)
LIBC_OBJS += $(EMMALLOC_OBJS)
else ifeq ($(MALLOC_IMPL),none)
# No object files to add.
else
$(error unknown malloc implementation $(MALLOC_IMPL))
endif
# Add libc-bottom-half's objects.
LIBC_OBJS += $(LIBC_BOTTOM_HALF_ALL_OBJS)
ifeq ($(BUILD_LIBC_TOP_HALF),yes)
# libc-top-half is musl.
LIBC_OBJS += $(LIBC_TOP_HALF_ALL_OBJS)
endif
LIBC_OBJS += $(FTS_OBJS)
MUSL_PRINTSCAN_OBJS = $(call objs,$(MUSL_PRINTSCAN_SOURCES))
MUSL_PRINTSCAN_LONG_DOUBLE_OBJS = $(patsubst %.o,%.long-double.o,$(MUSL_PRINTSCAN_OBJS))
MUSL_PRINTSCAN_NO_FLOATING_POINT_OBJS = $(patsubst %.o,%.no-floating-point.o,$(MUSL_PRINTSCAN_OBJS))
BULK_MEMORY_OBJS = $(call objs,$(BULK_MEMORY_SOURCES))
LIBWASI_EMULATED_MMAN_OBJS = $(call objs,$(LIBWASI_EMULATED_MMAN_SOURCES))
LIBWASI_EMULATED_PROCESS_CLOCKS_OBJS = $(call objs,$(LIBWASI_EMULATED_PROCESS_CLOCKS_SOURCES))
LIBWASI_EMULATED_GETPID_OBJS = $(call objs,$(LIBWASI_EMULATED_GETPID_SOURCES))
LIBWASI_EMULATED_SIGNAL_OBJS = $(call objs,$(LIBWASI_EMULATED_SIGNAL_SOURCES))
LIBWASI_EMULATED_SIGNAL_MUSL_OBJS = $(call objs,$(LIBWASI_EMULATED_SIGNAL_MUSL_SOURCES))
LIBWASI_EMULATED_PTHREAD_OBJS = $(call objs,$(LIBWASI_EMULATED_PTHREAD_SOURCES))
LIBDL_OBJS = $(call objs,$(LIBDL_SOURCES))
LIBSETJMP_OBJS = $(call objs,$(LIBSETJMP_SOURCES))
LIBC_BOTTOM_HALF_CRT_OBJS = $(call objs,$(LIBC_BOTTOM_HALF_CRT_SOURCES))
LIBC_NONLTO_OBJS = $(call objs,$(LIBC_NONLTO_SOURCES))

# These variables describe the locations of various files and
# directories in the generated sysroot tree.
SYSROOT_LIB := $(SYSROOT)/lib/$(TARGET_TRIPLE)
ifneq ($(LTO),no)
override SYSROOT_LIB := $(SYSROOT_LIB)/llvm-lto/$(CLANG_VERSION)
endif
SYSROOT_INC = $(SYSROOT)/include/$(TARGET_TRIPLE)
SYSROOT_SHARE = $(SYSROOT)/share/$(TARGET_TRIPLE)

default: finish

LIBC_SO_OBJS = $(patsubst %.o,%.pic.o,$(filter-out $(MUSL_PRINTSCAN_OBJS),$(LIBC_OBJS)))
MUSL_PRINTSCAN_LONG_DOUBLE_SO_OBJS = $(patsubst %.o,%.pic.o,$(MUSL_PRINTSCAN_LONG_DOUBLE_OBJS))
LIBWASI_EMULATED_MMAN_SO_OBJS = $(patsubst %.o,%.pic.o,$(LIBWASI_EMULATED_MMAN_OBJS))
LIBWASI_EMULATED_PROCESS_CLOCKS_SO_OBJS = $(patsubst %.o,%.pic.o,$(LIBWASI_EMULATED_PROCESS_CLOCKS_OBJS))
LIBWASI_EMULATED_GETPID_SO_OBJS = $(patsubst %.o,%.pic.o,$(LIBWASI_EMULATED_GETPID_OBJS))
LIBWASI_EMULATED_SIGNAL_SO_OBJS = $(patsubst %.o,%.pic.o,$(LIBWASI_EMULATED_SIGNAL_OBJS))
LIBWASI_EMULATED_SIGNAL_MUSL_SO_OBJS = $(patsubst %.o,%.pic.o,$(LIBWASI_EMULATED_SIGNAL_MUSL_OBJS))
LIBWASI_EMULATED_PTHREAD_SO_OBJS = $(patsubst %.o,%.pic.o,$(LIBWASI_EMULATED_PTHREAD_OBJS))
LIBDL_SO_OBJS = $(patsubst %.o,%.pic.o,$(LIBDL_OBJS))
LIBSETJMP_SO_OBJS = $(patsubst %.o,%.pic.o,$(LIBSETJMP_OBJS))
BULK_MEMORY_SO_OBJS = $(patsubst %.o,%.pic.o,$(BULK_MEMORY_OBJS))
DLMALLOC_SO_OBJS = $(patsubst %.o,%.pic.o,$(DLMALLOC_OBJS))
LIBC_BOTTOM_HALF_ALL_SO_OBJS = $(patsubst %.o,%.pic.o,$(LIBC_BOTTOM_HALF_ALL_OBJS))
LIBC_TOP_HALF_ALL_SO_OBJS = $(patsubst %.o,%.pic.o,$(LIBC_TOP_HALF_ALL_OBJS))
FTS_SO_OBJS = $(patsubst %.o,%.pic.o,$(FTS_OBJS))

PIC_OBJS = \
	$(LIBC_SO_OBJS) \
	$(MUSL_PRINTSCAN_LONG_DOUBLE_SO_OBJS) \
	$(LIBWASI_EMULATED_MMAN_SO_OBJS) \
	$(LIBWASI_EMULATED_PROCESS_CLOCKS_SO_OBJS) \
	$(LIBWASI_EMULATED_GETPID_SO_OBJS) \
	$(LIBWASI_EMULATED_SIGNAL_SO_OBJS) \
	$(LIBWASI_EMULATED_SIGNAL_MUSL_SO_OBJS) \
	$(LIBWASI_EMULATED_PTHREAD_SO_OBJS) \
	$(LIBDL_SO_OBJS) \
	$(LIBSETJMP_SO_OBJS) \
	$(BULK_MEMORY_SO_OBJS) \
	$(DLMALLOC_SO_OBJS) \
	$(LIBC_BOTTOM_HALF_ALL_SO_OBJS) \
	$(LIBC_TOP_HALF_ALL_SO_OBJS) \
	$(LIBC_BOTTOM_HALF_CRT_OBJS) \
	$(FTS_SO_OBJS)

# Figure out what to do about compiler-rt.
#
# The compiler-rt library is not built here in the wasi-libc repository, but it
# is required to link artifacts. Notably `libc.so` and test and such all require
# it to exist. Currently the ways this is handled are:
#
# * If `BUILTINS_LIB` is defined at build time then that's assumed to be a path
#   to the libcompiler-rt.a. That's then ingested into the build here and copied
#   around to special locations to get the `*.so` rules below to work (see docs
#   there).
#
# * If `BUILTINS_LIB` is not defined then a known-good copy is downloaded from
#   wasi-sdk CI and used instead.
#
# In the future this may also want some form of configuration to support
# assuming the system compiler has a compiler-rt, e.g. if $(SYSTEM_BUILTINS_LIB)
# exists that should be used instead.
SYSTEM_BUILTINS_LIB := $(shell ${CC} ${CFLAGS} --print-libgcc-file-name)
SYSTEM_RESOURCE_DIR := $(shell ${CC} ${CFLAGS} -print-resource-dir)
BUILTINS_LIB_REL := $(subst $(SYSTEM_RESOURCE_DIR),,$(SYSTEM_BUILTINS_LIB))
TMP_RESOURCE_DIR := $(OBJDIR)/resource-dir
BUILTINS_LIB_PATH := $(TMP_RESOURCE_DIR)/$(BUILTINS_LIB_REL)
BUILTINS_LIB_DIR := $(dir $(BUILTINS_LIB_PATH))

ifneq ($(BUILTINS_LIB),)
$(BUILTINS_LIB_PATH): $(BUILTINS_LIB)
	mkdir -p $(BUILTINS_LIB_DIR)
	cp $(BUILTINS_LIB) $(BUILTINS_LIB_PATH)
else

BUILTINS_URL := https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-25/libclang_rt.builtins-wasm32-wasi-25.0.tar.gz

$(BUILTINS_LIB_PATH):
	mkdir -p $(BUILTINS_LIB_DIR)
	curl -sSfL $(BUILTINS_URL) | \
		tar xzf - -C $(BUILTINS_LIB_DIR) --strip-components 1
	if [ ! -f $(BUILTINS_LIB_PATH) ]; then \
	  mv $(BUILTINS_LIB_DIR)/*.a $(BUILTINS_LIB_PATH); \
	fi
endif

builtins: $(BUILTINS_LIB_PATH)

# TODO: Specify SDK version, e.g. libc.so.wasi-sdk-21, as SO_NAME once `wasm-ld`
# supports it.
#
# Note that we collect the object files for each shared library into a .a and
# link that using `--whole-archive` rather than pass the object files directly
# to CC.  This is a workaround for a Windows command line size limitation.  See
# the `%.a` rule below for details.

# Note: libc.so is special because it shouldn't link to libc.so, and the
# -nodefaultlibs flag here disables the default `-lc` logic that clang
# has. Note though that this also disables linking of compiler-rt
# libraries so that is explicitly passed in via `$(BUILTINS_LIB_PATH)`
#
# Note: --allow-undefined-file=linker-provided-symbols.txt is
# a workaround for https://github.com/llvm/llvm-project/issues/103592
$(SYSROOT_LIB)/libc.so: $(OBJDIR)/libc.so.a $(BUILTINS_LIB_PATH)
	$(CC) --target=${TARGET_TRIPLE} -nodefaultlibs \
	-shared --sysroot=$(SYSROOT) \
	-o $@ -Wl,--whole-archive $< -Wl,--no-whole-archive \
	-Wl,--allow-undefined-file=linker-provided-symbols.txt \
	$(BUILTINS_LIB_PATH) \
	$(EXTRA_CFLAGS) $(LDFLAGS)

# Note that unlike `libc.so` above this rule does not pass `-nodefaultlibs`
# which means that libc will be linked by default. Additionally clang will try
# to find, locate, and link compiler-rt. To get compiler-rt to work a
# `-resource-dir` argument is passed to ensure that our custom
# `TMP_RESOURCE_DIR` built here locally is used instead of the system directory
# which may or may not already have compiler-rt.
$(SYSROOT_LIB)/%.so: $(OBJDIR)/%.so.a $(SYSROOT_LIB)/libc.so
	$(CC) --target=${TARGET_TRIPLE} \
	-shared --sysroot=$(SYSROOT) \
	-o $@ -Wl,--whole-archive $< -Wl,--no-whole-archive \
	-Wl,--allow-undefined-file=linker-provided-symbols.txt \
	-resource-dir $(TMP_RESOURCE_DIR) \
	$(EXTRA_CFLAGS) $(LDFLAGS)

$(OBJDIR)/libc.so.a: $(LIBC_SO_OBJS) $(MUSL_PRINTSCAN_LONG_DOUBLE_SO_OBJS)

$(OBJDIR)/libwasi-emulated-mman.so.a: $(LIBWASI_EMULATED_MMAN_SO_OBJS)

$(OBJDIR)/libwasi-emulated-process-clocks.so.a: $(LIBWASI_EMULATED_PROCESS_CLOCKS_SO_OBJS)

$(OBJDIR)/libwasi-emulated-getpid.so.a: $(LIBWASI_EMULATED_GETPID_SO_OBJS)

$(OBJDIR)/libwasi-emulated-signal.so.a: $(LIBWASI_EMULATED_SIGNAL_SO_OBJS) $(LIBWASI_EMULATED_SIGNAL_MUSL_SO_OBJS)

$(OBJDIR)/libwasi-emulated-pthread.so.a: $(LIBWASI_EMULATED_PTHREAD_SO_OBJS)

$(OBJDIR)/libdl.so.a: $(LIBDL_SO_OBJS)

$(OBJDIR)/libsetjmp.so.a: $(LIBSETJMP_SO_OBJS)

$(SYSROOT_LIB)/libc.a: $(LIBC_OBJS)

$(SYSROOT_LIB)/libc-printscan-long-double.a: $(MUSL_PRINTSCAN_LONG_DOUBLE_OBJS)

$(SYSROOT_LIB)/libc-printscan-no-floating-point.a: $(MUSL_PRINTSCAN_NO_FLOATING_POINT_OBJS)

$(SYSROOT_LIB)/libwasi-emulated-mman.a: $(LIBWASI_EMULATED_MMAN_OBJS)

$(SYSROOT_LIB)/libwasi-emulated-process-clocks.a: $(LIBWASI_EMULATED_PROCESS_CLOCKS_OBJS)

$(SYSROOT_LIB)/libwasi-emulated-getpid.a: $(LIBWASI_EMULATED_GETPID_OBJS)

$(SYSROOT_LIB)/libwasi-emulated-signal.a: $(LIBWASI_EMULATED_SIGNAL_OBJS) $(LIBWASI_EMULATED_SIGNAL_MUSL_OBJS)

$(SYSROOT_LIB)/libwasi-emulated-pthread.a: $(LIBWASI_EMULATED_PTHREAD_OBJS)

$(SYSROOT_LIB)/libdl.a: $(LIBDL_OBJS)

$(SYSROOT_LIB)/libsetjmp.a: $(LIBSETJMP_OBJS)

%.a:
	@mkdir -p "$(@D)"
	# On Windows, the commandline for the ar invocation got too long, so it needs to be split up.
	$(AR) crs $@ $(wordlist 1, 199, $(sort $^))
	$(AR) crs $@ $(wordlist 200, 399, $(sort $^))
	$(AR) crs $@ $(wordlist 400, 599, $(sort $^))
	$(AR) crs $@ $(wordlist 600, 799, $(sort $^))
	# This might eventually overflow again, but at least it'll do so in a loud way instead of
	# silently dropping the tail.
	$(AR) crs $@ $(wordlist 800, 100000, $(sort $^))

$(PIC_OBJS): CFLAGS += -fPIC -fvisibility=default

$(LIBC_NONLTO_OBJS): CFLAGS := $(filter-out -flto% -fno-lto, $(CFLAGS)) -fno-lto

$(MUSL_PRINTSCAN_OBJS): CFLAGS += \
	    -D__wasilibc_printscan_no_long_double \
	    -D__wasilibc_printscan_full_support_option="\"add -lc-printscan-long-double to the link command\""

$(MUSL_PRINTSCAN_NO_FLOATING_POINT_OBJS): CFLAGS += \
	    -D__wasilibc_printscan_no_floating_point \
	    -D__wasilibc_printscan_floating_point_support_option="\"remove -lc-printscan-no-floating-point from the link command\""

# TODO: apply -mbulk-memory globally, once
# https://github.com/llvm/llvm-project/issues/52618 is resolved
$(BULK_MEMORY_OBJS) $(BULK_MEMORY_SO_OBJS): CFLAGS += \
        -mbulk-memory

$(BULK_MEMORY_OBJS) $(BULK_MEMORY_SO_OBJS): CFLAGS += \
        -DBULK_MEMORY_THRESHOLD=$(BULK_MEMORY_THRESHOLD)

$(LIBSETJMP_OBJS) $(LIBSETJMP_SO_OBJS): CFLAGS += \
        -mllvm -wasm-enable-sjlj

$(LIBWASI_EMULATED_SIGNAL_MUSL_OBJS) $(LIBWASI_EMULATED_SIGNAL_MUSL_SO_OBJS): CFLAGS += \
	    -D_WASI_EMULATED_SIGNAL

$(OBJDIR)/%.long-double.pic.o: %.c $(INCLUDE_DIRS)
	@mkdir -p "$(@D)"
	$(CC) $(CFLAGS) -MD -MP -o $@ -c $<

$(OBJDIR)/wasip2_component_type.pic.o $(OBJDIR)/wasip2_component_type.o: $(LIBC_BOTTOM_HALF_SOURCES)/wasip2_component_type.o
	@mkdir -p "$(@D)"
	cp $< $@

$(OBJDIR)/%.pic.o: %.c $(INCLUDE_DIRS)
	@mkdir -p "$(@D)"
	$(CC) $(CFLAGS) -MD -MP -o $@ -c $<

$(OBJDIR)/%.long-double.o: %.c $(INCLUDE_DIRS)
	@mkdir -p "$(@D)"
	$(CC) $(CFLAGS) -MD -MP -o $@ -c $<

$(OBJDIR)/%.no-floating-point.o: %.c $(INCLUDE_DIRS)
	@mkdir -p "$(@D)"
	$(CC) $(CFLAGS) -MD -MP -o $@ -c $<

$(OBJDIR)/%.o: %.c $(INCLUDE_DIRS)
	@mkdir -p "$(@D)"
	$(CC) $(CFLAGS) -MD -MP -o $@ -c $<

$(OBJDIR)/%.o: %.s $(INCLUDE_DIRS)
	@mkdir -p "$(@D)"
	$(CC) $(ASMFLAGS) -o $@ -c $<

-include $(shell find $(OBJDIR) -name \*.d)

$(DLMALLOC_OBJS) $(DLMALLOC_SO_OBJS): CFLAGS += \
    -I$(DLMALLOC_INC)

$(STARTUP_FILES) $(LIBC_BOTTOM_HALF_ALL_OBJS) $(LIBC_BOTTOM_HALF_ALL_SO_OBJS): CFLAGS += \
    -I$(LIBC_BOTTOM_HALF_HEADERS_PRIVATE) \
    -I$(LIBC_BOTTOM_HALF_CLOUDLIBC_SRC_INC) \
    -I$(LIBC_BOTTOM_HALF_CLOUDLIBC_SRC) \
    -I$(LIBC_TOP_HALF_MUSL_SRC_DIR)/include \
    -I$(LIBC_TOP_HALF_MUSL_SRC_DIR)/internal

$(LIBC_TOP_HALF_ALL_OBJS) $(LIBC_TOP_HALF_ALL_SO_OBJS) $(MUSL_PRINTSCAN_LONG_DOUBLE_OBJS) $(MUSL_PRINTSCAN_LONG_DOUBLE_SO_OBJS) $(MUSL_PRINTSCAN_NO_FLOATING_POINT_OBJS) $(LIBWASI_EMULATED_SIGNAL_MUSL_OBJS) $(LIBWASI_EMULATED_SIGNAL_MUSL_SO_OBJS) $(LIBDL_OBJS) $(LIBDL_SO_OBJS) $(LIBSETJMP_OBJS) $(LIBSETJMP_SO_OBJS): CFLAGS += \
    -I$(LIBC_TOP_HALF_MUSL_SRC_DIR)/include \
    -I$(LIBC_TOP_HALF_MUSL_SRC_DIR)/internal \
    -I$(LIBC_TOP_HALF_MUSL_DIR)/arch/wasm32 \
    -I$(LIBC_TOP_HALF_MUSL_DIR)/arch/generic \
    -I$(LIBC_TOP_HALF_HEADERS_PRIVATE) \
    -Wno-parentheses \
    -Wno-shift-op-parentheses \
    -Wno-bitwise-op-parentheses \
    -Wno-logical-op-parentheses \
    -Wno-string-plus-int \
    -Wno-dangling-else \
    -Wno-unknown-pragmas

$(FTS_OBJS) $(FTS_SO_OBJS): CFLAGS += \
    -I$(MUSL_FTS_SRC_DIR) \
    -I$(FTS_SRC_DIR) # for config.h

$(LIBWASI_EMULATED_PROCESS_CLOCKS_OBJS) $(LIBWASI_EMULATED_PROCESS_CLOCKS_SO_OBJS): CFLAGS += \
    -I$(LIBC_BOTTOM_HALF_CLOUDLIBC_SRC)

$(LIBWASI_EMULATED_PTHREAD_OBJS) $(LIBWASI_EMULATED_PTHREAD_SO_OBJS): CFLAGS += \
    -I$(LIBC_TOP_HALF_MUSL_SRC_DIR)/include \
    -I$(LIBC_TOP_HALF_MUSL_SRC_DIR)/internal \
    -I$(LIBC_TOP_HALF_MUSL_DIR)/arch/wasm32 \
    -D_WASI_EMULATED_PTHREAD

# emmalloc uses a lot of pointer type-punning, which is UB under strict aliasing,
# and this was found to have real miscompilations in wasi-libc#421.
$(EMMALLOC_OBJS): CFLAGS += \
    -fno-strict-aliasing

ALL_POSSIBLE_HEADERS += $(shell find $(LIBC_TOP_HALF_MUSL_DIR) -name \*.h)
ALL_POSSIBLE_HEADERS += $(shell find $(LIBC_BOTTOM_HALF_HEADERS_PUBLIC) -name \*.h)
ALL_POSSIBLE_HEADERS += $(shell find $(MUSL_FTS_SRC_DIR) -name \*.h)
$(INCLUDE_DIRS): $(ALL_POSSIBLE_HEADERS)
	#
	# Install the include files.
	#
	SYSROOT_INC=$(SYSROOT_INC) TARGET_TRIPLE=$(TARGET_TRIPLE) \
	    $(CURDIR)/scripts/install-include-headers.sh
	# Stamp the include installation.
	@mkdir -p $(@D)
	touch $@

STARTUP_FILES := $(OBJDIR)/copy-startup-files.stamp
$(STARTUP_FILES): $(INCLUDE_DIRS) $(LIBC_BOTTOM_HALF_CRT_OBJS)
	#
	# Install the startup files (crt1.o, etc.).
	#
	mkdir -p "$(SYSROOT_LIB)"
	cp $(LIBC_BOTTOM_HALF_CRT_OBJS) "$(SYSROOT_LIB)"

	# Stamp the startup file installation.
	@mkdir -p $(@D)
	touch $@

# TODO: As of this writing, wasi_thread_start.s uses non-position-independent
# code, and I'm not sure how to make it position-independent.  Once we've done
# that, we can enable libc.so for the wasi-threads build.
ifneq ($(THREAD_MODEL), posix)
LIBC_SO = \
	$(SYSROOT_LIB)/libc.so \
	$(SYSROOT_LIB)/libwasi-emulated-mman.so \
	$(SYSROOT_LIB)/libwasi-emulated-process-clocks.so \
	$(SYSROOT_LIB)/libwasi-emulated-getpid.so \
	$(SYSROOT_LIB)/libwasi-emulated-signal.so \
	$(SYSROOT_LIB)/libwasi-emulated-pthread.so \
	$(SYSROOT_LIB)/libdl.so
ifeq ($(BUILD_LIBSETJMP),yes)
LIBC_SO += \
	$(SYSROOT_LIB)/libsetjmp.so
endif
endif

libc_so: $(INCLUDE_DIRS) $(LIBC_SO)

STATIC_LIBS = \
    $(SYSROOT_LIB)/libc.a \
    $(SYSROOT_LIB)/libc-printscan-long-double.a \
    $(SYSROOT_LIB)/libc-printscan-no-floating-point.a \
    $(SYSROOT_LIB)/libwasi-emulated-mman.a \
    $(SYSROOT_LIB)/libwasi-emulated-process-clocks.a \
    $(SYSROOT_LIB)/libwasi-emulated-getpid.a \
    $(SYSROOT_LIB)/libwasi-emulated-signal.a \
    $(SYSROOT_LIB)/libdl.a
ifneq ($(THREAD_MODEL), posix)
    STATIC_LIBS += \
        $(SYSROOT_LIB)/libwasi-emulated-pthread.a
endif
ifeq ($(BUILD_LIBSETJMP),yes)
STATIC_LIBS += \
	$(SYSROOT_LIB)/libsetjmp.a
endif

libc: $(INCLUDE_DIRS) $(STATIC_LIBS)

DUMMY := m rt pthread crypt util xnet resolv
DUMMY_LIBS := $(patsubst %,$(SYSROOT_LIB)/lib%.a,$(DUMMY))
$(DUMMY_LIBS):
	#
	# Create empty placeholder libraries.
	#
	mkdir -p "$(SYSROOT_LIB)"
	for lib in $@; do \
	    $(AR) crs "$$lib"; \
	done

no-check-symbols: $(STARTUP_FILES) libc $(DUMMY_LIBS)
	#
	# The build succeeded! The generated sysroot is in $(SYSROOT).
	#

finish: no-check-symbols

ifeq ($(LTO),no)
# The check for defined and undefined symbols expects there to be a heap
# allocator (providing malloc, calloc, free, etc). Skip this step if the build
# is done without a malloc implementation.
ifneq ($(MALLOC_IMPL),none)
finish: check-symbols
endif
endif

install: finish
	mkdir -p "$(INSTALL_DIR)"
	cp -p -r "$(SYSROOT)/lib" "$(SYSROOT)/share" "$(SYSROOT)/include" "$(INSTALL_DIR)"

DEFINED_SYMBOLS = $(SYSROOT_SHARE)/defined-symbols.txt
UNDEFINED_SYMBOLS = $(SYSROOT_SHARE)/undefined-symbols.txt

ifeq ($(WASI_SNAPSHOT),p2)
EXPECTED_TARGET_DIR = expected/wasm32-wasip2
else
ifeq ($(THREAD_MODEL),posix)
EXPECTED_TARGET_DIR = expected/wasm32-wasip1-threads
else
EXPECTED_TARGET_DIR = expected/wasm32-wasip1
endif
endif


check-symbols: $(STARTUP_FILES) libc
	#
	# Collect metadata on the sysroot and perform sanity checks.
	#
	mkdir -p "$(SYSROOT_SHARE)"

	#
	# Collect symbol information.
	#
	@# TODO: Use llvm-nm --extern-only instead of grep. This is blocked on
	@# LLVM PR40497, which is fixed in 9.0, but not in 8.0.
	@# Ignore certain llvm builtin symbols such as those starting with __mul
	@# since these dependencies can vary between llvm versions.
	"$(NM)" --defined-only "$(SYSROOT_LIB)"/libc.a "$(SYSROOT_LIB)"/libwasi-emulated-*.a "$(SYSROOT_LIB)"/*.o \
	    |grep ' [[:upper:]] ' |sed 's/.* [[:upper:]] //' |LC_ALL=C sort |uniq > "$(DEFINED_SYMBOLS)"
	for undef_sym in $$("$(NM)" --undefined-only "$(SYSROOT_LIB)"/libc.a "$(SYSROOT_LIB)"/libc-*.a "$(SYSROOT_LIB)"/*.o \
	    |grep ' U ' |sed 's/.* U //' |LC_ALL=C sort |uniq); do \
	    grep -q '\<'$$undef_sym'\>' "$(DEFINED_SYMBOLS)" || echo $$undef_sym; \
	done | grep -E -v "^__mul|__memory_base|__indirect_function_table|__tls_base" > "$(UNDEFINED_SYMBOLS)"
	grep '^_*imported_wasi_' "$(UNDEFINED_SYMBOLS)" \
	    > "$(SYSROOT_LIB)/libc.imports"

	#
	# Generate a test file that includes all public C header files.
	#
	# setjmp.h is excluded because it requires a different compiler option
	#
	cd "$(SYSROOT_INC)" && \
	  for header in $$(find . -type f -not -name mman.h -not -name signal.h -not -name times.h -not -name resource.h -not -name setjmp.h $(INCLUDE_ALL_CLAUSES) |grep -v /bits/ |grep -v /c++/); do \
	      echo '#include <'$$header'>' | sed 's/\.\///' ; \
	done |LC_ALL=C sort >$(SYSROOT_SHARE)/include-all.c ; \
	cd - >/dev/null

	#
	# Test that it compiles.
	#
	$(CC) $(CFLAGS) -fsyntax-only "$(SYSROOT_SHARE)/include-all.c" -Wno-\#warnings

	#
	# Collect all the predefined macros, except for compiler version macros
	# which we don't need to track here.
	#
	@#
	@# For the __*_ATOMIC_*_LOCK_FREE macros, squash individual compiler names
	@# to attempt, toward keeping these files compiler-independent.
	@#
	@# We have to add `-isystem $(SYSROOT_INC)` because otherwise clang puts
	@# its builtin include path first, which produces compiler-specific
	@# output.
	@#
	@# TODO: Filter out __NO_MATH_ERRNO_ and a few __*WIDTH__ that are new to clang 14.
	@# TODO: Filter out __GCC_HAVE_SYNC_COMPARE_AND_SWAP_* that are new to clang 16.
	@# TODO: Filter out __FPCLASS_* that are new to clang 17.
	@# TODO: Filter out __FLT128_* that are new to clang 18.
	@# TODO: Filter out __MEMORY_SCOPE_* that are new to clang 18.
	@# TODO: Filter out __GCC_(CON|DE)STRUCTIVE_SIZE that are new to clang 19.
	@# TODO: Filter out __STDC_EMBED_* that are new to clang 19.
	@# TODO: Filter out __*_NORM_MAX__ that are new to clang 19.
	@# TODO: Filter out __INT*_C() that are new to clang 20.
	@# TODO: clang defined __FLT_EVAL_METHOD__ until clang 15, so we force-undefine it
	@# for older versions.
	@# TODO: Undefine __wasm_mutable_globals__ and __wasm_sign_ext__, that are new to
	@# clang 16 for -mcpu=generic.
	@# TODO: Undefine __wasm_multivalue__ and __wasm_reference_types__, that are new to
	@# clang 19 for -mcpu=generic.
	@# TODO: Undefine __wasm_nontrapping_fptoint__, __wasm_bulk_memory__ and
	@# __wasm_bulk_memory_opt__, that are new to clang 20.
	@# TODO: As of clang 16, __GNUC_VA_LIST is #defined without a value.
	$(CC) $(CFLAGS) "$(SYSROOT_SHARE)/include-all.c" \
	    -isystem $(SYSROOT_INC) \
	    -std=gnu17 \
	    -E -dM -Wno-\#warnings \
	    -D_ALL_SOURCE \
	    -U__llvm__ \
	    -U__clang__ \
	    -U__clang_major__ \
	    -U__clang_minor__ \
	    -U__clang_patchlevel__ \
	    -U__clang_version__ \
	    -U__clang_literal_encoding__ \
	    -U__clang_wide_literal_encoding__ \
	    -U__wasm_extended_const__ \
	    -U__wasm_mutable_globals__ \
	    -U__wasm_sign_ext__ \
	    -U__wasm_multivalue__ \
	    -U__wasm_reference_types__ \
	    -U__wasm_nontrapping_fptoint__ \
	    $(if $(filter-out expected/wasm32-wasip1-threads,$(EXPECTED_TARGET_DIR)),-U__wasm_bulk_memory__) \
	    -U__wasm_bulk_memory_opt__ \
	    -U__GNUC__ \
	    -U__GNUC_MINOR__ \
	    -U__GNUC_PATCHLEVEL__ \
	    -U__VERSION__ \
	    -U__NO_MATH_ERRNO__ \
	    -U__BITINT_MAXWIDTH__ \
	    -U__FLT_EVAL_METHOD__ -Wno-builtin-macro-redefined \
	    | sed -e 's/__[[:upper:][:digit:]]*_ATOMIC_\([[:upper:][:digit:]_]*\)_LOCK_FREE/__compiler_ATOMIC_\1_LOCK_FREE/' \
	    | sed -e 's/__GNUC_VA_LIST $$/__GNUC_VA_LIST 1/' \
	    | grep -v '^#define __\(BOOL\|INT_\(LEAST\|FAST\)\(8\|16\|32\|64\)\|INT\|LONG\|LLONG\|SHRT\)_WIDTH__' \
	    | grep -v '^#define __GCC_HAVE_SYNC_COMPARE_AND_SWAP_\(1\|2\|4\|8\)' \
	    | grep -v '^#define __FPCLASS_' \
	    | grep -v '^#define __FLT128_' \
	    | grep -v '^#define __MEMORY_SCOPE_' \
	    | grep -v '^#define __GCC_\(CON\|DE\)STRUCTIVE_SIZE' \
	    | grep -v '^#define __STDC_EMBED_' \
	    | grep -v '^#define __\(DBL\|FLT\|LDBL\)_NORM_MAX__' \
	    | grep -v '^#define NDEBUG' \
	    | grep -v '^#define __OPTIMIZE__' \
	    | grep -v '^#define assert' \
	    | grep -v '^#define __NO_INLINE__' \
	    | grep -v '^#define __U\?INT.*_C(' \
	    > "$(SYSROOT_SHARE)/predefined-macros.txt"

	# Check that the computed metadata matches the expected metadata.
	# This ignores whitespace because on Windows the output has CRLF line endings.
	diff -wur "$(EXPECTED_TARGET_DIR)" "$(SYSROOT_SHARE)"


##### BINDINGS #################################################################
# The `bindings` target retrieves the necessary WIT files for the wasi-cli world
# and generates a header file used by the wasip2 target.
################################################################################

# The directory where we store files and tools for generating WASIp2 bindings
BINDING_WORK_DIR ?= build/bindings
# URL from which to retrieve the WIT files used to generate the WASIp2 bindings
WASI_CLI_URL ?= https://github.com/WebAssembly/wasi-cli/archive/refs/tags/v0.2.0.tar.gz
# URL from which to retrieve the `wit-bindgen` command used to generate the
# WASIp2 bindings.
WIT_BINDGEN_URL ?= https://github.com/bytecodealliance/wit-bindgen/releases/download/wit-bindgen-cli-0.17.0/wit-bindgen-v0.17.0-x86_64-linux.tar.gz

$(BINDING_WORK_DIR)/wasi-cli:
	mkdir -p "$(BINDING_WORK_DIR)"
	cd "$(BINDING_WORK_DIR)" && \
		curl -L "$(WASI_CLI_URL)" -o wasi-cli.tar.gz && \
		tar xf wasi-cli.tar.gz && \
		mv wasi-cli-* wasi-cli

$(BINDING_WORK_DIR)/wit-bindgen:
	mkdir -p "$(BINDING_WORK_DIR)"
	cd "$(BINDING_WORK_DIR)" && \
		curl -L "$(WIT_BINDGEN_URL)" -o wit-bindgen.tar.gz && \
		tar xf wit-bindgen.tar.gz && \
		mv wit-bindgen-* wit-bindgen

bindings: $(BINDING_WORK_DIR)/wasi-cli $(BINDING_WORK_DIR)/wit-bindgen
	cd "$(BINDING_WORK_DIR)" && \
		./wit-bindgen/wit-bindgen c \
			--autodrop-borrows yes \
			--rename-world wasip2 \
			--type-section-suffix __wasi_libc \
			--world wasi:cli/imports@0.2.0 \
			--rename wasi:clocks/monotonic-clock@0.2.0=monotonic_clock \
			--rename wasi:clocks/wall-clock@0.2.0=wall_clock \
			--rename wasi:filesystem/preopens@0.2.0=filesystem_preopens \
			--rename wasi:filesystem/types@0.2.0=filesystem \
			--rename wasi:io/error@0.2.0=io_error \
			--rename wasi:io/poll@0.2.0=poll \
			--rename wasi:io/streams@0.2.0=streams \
			--rename wasi:random/insecure-seed@0.2.0=random_insecure_seed \
			--rename wasi:random/insecure@0.2.0=random_insecure \
			--rename wasi:random/random@0.2.0=random \
			--rename wasi:sockets/instance-network@0.2.0=instance_network \
			--rename wasi:sockets/ip-name-lookup@0.2.0=ip_name_lookup \
			--rename wasi:sockets/network@0.2.0=network \
			--rename wasi:sockets/tcp-create-socket@0.2.0=tcp_create_socket \
			--rename wasi:sockets/tcp@0.2.0=tcp \
			--rename wasi:sockets/udp-create-socket@0.2.0=udp_create_socket \
			--rename wasi:sockets/udp@0.2.0=udp \
			--rename wasi:cli/environment@0.2.0=environment \
			--rename wasi:cli/exit@0.2.0=exit \
			--rename wasi:cli/stdin@0.2.0=stdin \
			--rename wasi:cli/stdout@0.2.0=stdout \
			--rename wasi:cli/stderr@0.2.0=stderr \
			--rename wasi:cli/terminal-input@0.2.0=terminal_input \
			--rename wasi:cli/terminal-output@0.2.0=terminal_output \
			--rename wasi:cli/terminal-stdin@0.2.0=terminal_stdin \
			--rename wasi:cli/terminal-stdout@0.2.0=terminal_stdout \
			--rename wasi:cli/terminal-stderr@0.2.0=terminal_stderr \
			./wasi-cli/wit && \
		mv wasip2.h ../../libc-bottom-half/headers/public/wasi/ && \
		mv wasip2_component_type.o ../../libc-bottom-half/sources && \
		sed 's_#include "wasip2\.h"_#include "wasi/wasip2.h"_' \
			< wasip2.c \
			> ../../libc-bottom-half/sources/wasip2.c && \
		rm wasip2.c


clean:
	$(RM) -r "$(BINDING_WORK_DIR)"
	$(RM) -r "$(OBJDIR)"
	$(RM) -r "$(SYSROOT)"

.PHONY: default libc libc_so finish install clean check-symbols no-check-symbols bindings
