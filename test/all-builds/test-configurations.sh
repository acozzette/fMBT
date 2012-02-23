#!/bin/bash

# fMBT, free Model Based Testing tool
# Copyright (c) 2012, Intel Corporation.
#
# This program is free software; you can redistribute it and/or modify it
# under the terms and conditions of the GNU Lesser General Public License,
# version 2.1, as published by the Free Software Foundation.
#
# This program is distributed in the hope it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public License for
# more details.
#
# You should have received a copy of the GNU Lesser General Public License along with
# this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin St - Fifth Floor, Boston, MA 02110-1301 USA.

##########################################
# This script demonstrates configuration testing: test all
# combinations of configurations.
#

# Commands for launching a virtual machine and logging in it. The
# virtual machines should have ssh server installed. Launch command
# should be such that when the process is killed nothing should be
# saved. Install ssh-keys to the virtual machines.

# To make this run faster:
# - install caching http proxy (like squid) on your host
# - set http_proxy=http://<your-ip>:<squid-port> when you run the tests

DEBIAN_VM_LAUNCH="kvm -m 1024 -nographic -snapshot -hda $HOME/emu/debian/debian.hda -net nic,model=virtio -net user,hostfwd=tcp::55522-:22"
SSH_DEBIAN_USER="ssh -p 55522 debian@localhost"
SSH_DEBIAN_ROOT="ssh -p 55522 root@localhost"

FEDORA_VM_LAUNCH="kvm -m 1024 -nographic -snapshot -hda $HOME/emu/fedora/fedora.hda -net nic,model=virtio -net user,hostfwd=tcp::55622-:22"
SSH_FEDORA_USER="ssh -p 55622 fedora@localhost"
SSH_FEDORA_ROOT="ssh -p 55622 root@localhost"

##########################################
# Setup test environment

cd "$(dirname "$0")"
THIS_TEST_DIR="$PWD"
LOGFILE=/tmp/fmbt.test.all-builds.log
SOURCEDIR=/tmp/fmbt.test.all-builds/src
CLEANGITDIR=/tmp/fmbt.test.all-builds/clean
GITDIR=/tmp/fmbt.test.all-builds/git
rm -rf "$LOGFILE"
FMBT_SOURCE_DIR="$PWD/../.."

SKIP_PATH_CHECKS=1
source ../functions.sh

rm -rf "$GITDIR"
mkdir -p "$GITDIR"

rm -rf "$CLEANGITDIR"
mkdir -p "$CLEANGITDIR"

rm -rf "$SOURCEDIR"
mkdir -p "$SOURCEDIR"

BRANCH=$(git branch | awk '/\*/{print $2}')

cd "$FMBT_SOURCE_DIR"
( git archive $BRANCH | tar xvf - -C "$CLEANGITDIR" ) >>$LOGFILE 2>&1 || {
    echo "Unpacking \"git archive $BRANCH\" into \"$CLEANGITDIR\" failed, see $LOGFILE"
    exit 1
}

cd "$THIS_TEST_DIR"

##########################################
# Test model states:
#
# prepare_source -> build_n_install -> test* -> cleanup
#     ^                                            |
#     |                                            |
#     +--------------------------------------------+
#
# *) run a test set suitable for the installed
#    target

fmbt-gt -o testmodel.lsts -f - <<EOF
P(prepare_source,  "gt:istate") ->
P(prepare_source,  "gt:istate")

T(prepare_source,  "iSourceTarGz",       build_n_install)
T(prepare_source,  "iSourceGitClone",    build_n_install)

T(build_n_install, "iMakeInstDebian",    test_fmbt)
T(build_n_install, "iMakeInstFedora",    test_fmbt)
T(build_n_install, "iMakeInstDroid",     test_fmbtdroid)
T(build_n_install, "iAndroidBuild",      test_android)
T(build_n_install, "iBuildInstDebPkg",   test_fmbt)
T(build_n_install, "iBuildInstRPMPkg",   test_fmbt)

T(test_fmbt,       "iTestFmbt",          cleanup)
T(test_fmbtdroid,  "iTestFmbtDroid",     cleanup)
T(test_android,    "iTestOnAndroid",     cleanup)

T(cleanup,         "iCleanup",           prepare_source)
EOF

##########################################
# Test steps. These shell functions will be called when the test is
# executed. For this example they only print what would be done.

# Source steps set current working directory to the directory where
# clean sources of wanted type can be found.

iSourceTarGz() {
    teststep "use fmbt.tar.gz..."
    cd "$CLEANGITDIR"

    rm -rf "$SOURCEDIR"
    mkdir -p "$SOURCEDIR"

    rm -rf "$GITDIR"
    mkdir -p "$GITDIR"

    cp -r "$CLEANGITDIR"/* "$GITDIR/"

    cd "$GITDIR"

    echo "1: running make dist" >> $LOGFILE
    ./autogen.sh >> $LOGFILE 2>&1
    ./configure >> $LOGFILE 2>&1
    make dist >> $LOGFILE 2>&1

    [ -f fmbt*.tar.gz ] || {
        testfailed
        exit 1
    }
    echo "" >> $LOGFILE
    echo "2: unpacking " fmbt*.tar.gz " into $SOURCEDIR" >> $LOGFILE
    tar xzvf fmbt*.tar.gz -C "$SOURCEDIR" >> $LOGFILE
    cd "$SOURCEDIR"/fmbt*
    if [ ! -f "configure" ]; then
        echo "configure missing" >> $LOGFILE
        testfailed
        exit 1
    fi
    if [ ! -f "README" ]; then
        echo "README missing" >> $LOGFILE
        testfailed
        exit 1
    fi
    testpassed
}

iSourceGitClone() {
    teststep "use git clone..."
    cd "$CLEANGITDIR"

    rm -rf "$GITDIR"
    mkdir -p "$GITDIR"

    cp -r "$CLEANGITDIR"/* "$GITDIR/"

    if [ ! -f "$GITDIR/autogen.sh" ] || [ -f "$GITDIR/configure" ]; then
        echo "$GITDIR/autogen.sh does not, or $GITDIR/configure exists in $GITDIR" >> $LOGFILE
        testfailed
        exit 1
    fi
    cd "$GITDIR"
    testpassed
}

helperMakeMakeInstall() {

    echo | $SSH_VM_USER "cd fmbt; [ ! -f configure ] && ./autogen.sh; ./configure && make" >> $LOGFILE 2>&1 || {
        echo "error when building through $SSH_VM_USER" >> $LOGFILE
        testfailed
        exit 1
    }

    echo | $SSH_VM_ROOT "cd /home/*/fmbt; make install" >> $LOGFILE 2>&1 || {
        echo "error when installing through $SSH_VM_ROOT" >> $LOGFILE
        testfailed
        exit 1
    }

}

iMakeInstDebian() {
    teststep "make install on Debian..."
    bash -c "$DEBIAN_VM_LAUNCH" >>$LOGFILE 2>&1 &
    VM_PID=$!
    sleep 15
    tar cf - . | $SSH_DEBIAN_USER "rm -rf fmbt; mkdir fmbt && cd fmbt && tar xfv -" >> $LOGFILE 2>&1 || {
        echo "error on copying files to Debian" >> $LOGFILE
        testfailed
        exit 1
    }

    echo | $SSH_DEBIAN_ROOT "export http_proxy=$http_proxy; apt-get update; cd /home/debian/fmbt; eval \"\$(awk '/apt-get install/{\$1=\"\"; print}' < README ) -y\" " >> $LOGFILE 2>&1 || {
        echo "error on apt-get installing dependencies on Debian" >> $LOGFILE
        testfailed
        exit 1
    }

    SSH_VM_USER="$SSH_DEBIAN_USER"

    SSH_VM_ROOT="$SSH_DEBIAN_ROOT"

    helperMakeMakeInstall

    testpassed
}

iMakeInstFedora() {
    teststep "make install on Fedora..."
    bash -c "$FEDORA_VM_LAUNCH" >>$LOGFILE 2>&1 &
    VM_PID=$!
    sleep 20

    tar cf - . | $SSH_FEDORA_USER "rm -rf fmbt; mkdir fmbt && cd fmbt && tar xfv -" >> $LOGFILE 2>&1 || {
        echo "error on copying files to Fedora" >> $LOGFILE
        testfailed
        exit 1
    }

    echo | $SSH_FEDORA_ROOT "echo proxy=$http_proxy >>/etc/yum.conf; cd /home/fedora/fmbt; eval \"\$(grep 'yum install' < README ) -y\" " >> $LOGFILE 2>&1

    SSH_VM_USER="$SSH_FEDORA_USER"

    SSH_VM_ROOT="$SSH_FEDORA_ROOT"
    
    helperMakeMakeInstall

    testpassed
}

iMakeInstDroid() {
    teststep "install fmbt-droid test not implemented"
    testskipped
}

iAndroidBuild() {
    teststep "building an android version with ndk-build..."
    testskipped
}

iBuildInstDebPkg() {
    teststep "dpkg-buildpackage test not implemented"
    testskipped
}

iBuildInstRPMPkg() {
    teststep "rpmbuild test not implemented"
    testskipped
}

iTestFmbt() {
    teststep "running fmbt tests"
    if [ -z "$VM_PID" ]; then
        echo >> $LOGFILE
        testskipped
        return 0
    fi

    echo | $SSH_VM_USER "( fmbt/test/tutorial/run.sh installed 2>&1; cat /tmp/fmbt.test.tutorial.log ) | nl" >> $LOGFILE 2>&1 || {
        echo "running tutorial test on Debian failed" >> $LOGFILE
        testfailed
        exit 1
    }

    LASTLINE=$(tail -n 1 $LOGFILE | sed 's/[ \t]*[0-9][0-9]*[ \t]*\# passed./ALL-OK/')

    if [ "$LASTLINE" != "ALL-OK" ]; then
        echo "unexpected last line of tutorial test results." >> $LOGFILE
        testfailed
        exit 1
    fi

    testpassed
}

iTestFmbtDroid() {
    teststep "test for fmbt_droid not implemented"
    testskipped
}

iTestOnAndroid() {
    teststep "test run on android not implemented"
    testskipped
}

iCleanup() {
    teststep "cleanup..."
    if [ "x$VM_PID" != "x" ]; then
        kill $VM_PID >> $LOGFILE 2>&1
        sleep 1;
        VM_PID=""
    fi
    testpassed
}

##########################################
# Test configuration.

# As we want to test every combination of 1) source and 2) target, and
# there's no 3rd configuration parameter, perm:2 covers all of them.
# no_progress end condition will top test generation after 4 generated
# steps without covering any new configurations.

cat > test.conf <<EOF
model     = "testmodel.lsts"
coverage  = "perm:2"
heuristic = "lookahead:4"
pass      = "no_progress:4"
# disable built-in coverage end condition:
fail      = "coverage:1.1"
fail      = "steps:100"
on_fail   = "exit"
EOF

##########################################
# Generate and run the test.

# This is an "offline" test: test.conf does not define an
# adapter. fmbt only generates and simulates the test run. Yet nothing
# is actually executed, simulated test steps are logged.
#
# We use fmbt-log to pick up the generated test from the log. Then we
# call the corresponding test step (shell function) for each step:

fmbt test.conf | fmbt-log -f '$as' | while read teststep; do

    $teststep || {
        echo "test step $teststep failed" >> $LOGFILE
        exit 1
    }

done

if grep -q '^# failed' $LOGFILE; then
    echo "some tests failed"
    exit 1
fi