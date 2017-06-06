#!/usr/bin/env bash

# Read config
. config/config

usage() {
    if [ -n "$1" ]; then
        echo "${0##*/} error: $1"
    else
        echo "Build deb packages in clean chroot"
        echo "Usage:"
        echo "    ${0##*/} <dist> [<pkg>]..."
        echo "        <dist> - one of the following distro codenames:"
        for dstr in $(ls "$PATCHES_DIR" 2>/dev/null); do
            printf "%16s %s\n" "" "${dstr}"
        done
        echo "        <pkg>  - list of packages to build (all by default):"
        for dsc in $(ls "$PKGS_DIR"/*.dsc 2>/dev/null); do
            dsc=${dsc##*/}
            printf "%16s %s\n" "" "${dsc%%_*}"
        done
        echo "    ${0##*/} clean"
        echo "        clean build directory"
        echo "Example:"
        echo "    ${0##*/} trusty libvirt"
    fi
    exit 1
}

get_src_dir() {
    name="$1"

    # First try using the *.orig.* file
    src_dir=$(ls "${PKGS_DIR}/${name}_"*.orig*z 2>/dev/null)
    src_dir=${src_dir%%.orig*}

    # It is a native package (no *.orig.* file)
    if [ -z "$src_dir" ]; then
        src_dir=$(ls "${PKGS_DIR}/${name}_"*.dsc 2>/dev/null)
        src_dir=${src_dir%%.dsc}
    fi

    src_dir=${src_dir##*/}
    src_dir=${src_dir/_/-}
    echo "$src_dir"
}

run() {
    "$@"
    if [ $? -ne 0 ]; then
        echo "Error executing: $@"
        exit 1
    fi
}

run_in_dir() {
    dir=$1
    shift

    pushd $dir
    "$@"
    if [ $? -ne 0 ]; then
        echo "Error executing: $@"
        exit 1
    fi
    popd
}

# Verify cmd arguments
if [ -z "$1" -o "$1" = "--help" -o "$1" = "-h" ]; then
    usage
fi

# Clean
if [ "$1" == "clean" ]; then
    run rm -rf $DEBS_DIR
    exit 0
fi

# Get distro and put to DIST env used by pbuilder
set -a
export DIST=$1
. $PBUILDER_CONF
set +a
shift

# Create base system if necessary
if [ ! -s "$BASETGZ" ]; then
    echo "Creating base system..."
    run pbuilder --create --configfile $PBUILDER_CONF
else
    # Update the base system
    echo "Updating base system..."
    run pbuilder --update --override-config --configfile $PBUILDER_CONF
fi

# Get pkgs to build
pkgs=$@
if [ -z "$pkgs" ]; then
    for dsc in $(ls "$PKGS_DIR"/*.dsc 2>/dev/null); do
        dsc=${dsc##*/}
        pkgs+="${dsc%%_*} "
    done
fi

# Enter the build directory
run mkdir -p $BUILD_DIR
run cd $BUILD_DIR

# Extract sources
for name in $pkgs; do
    dsc=$(ls "${PKGS_DIR}/${name}_"*.dsc 2>/dev/null)
    src_dir=$(get_src_dir $name)
    run rm -rf $src_dir
    run dpkg-source -x $dsc
done

# Apply patches
for name in $pkgs; do
    src_dir=$(get_src_dir $name)

    # Apply the DEBIAN-* pathes
    patches=$(ls "${PATCHES_DIR}/${DIST}/${name}/DEBIAN-"*.patch 2>/dev/null)
    for patch in $patches; do
        patch=$(readlink -e $patch)
        run_in_dir $src_dir patch -N -p1 < $patch
        #run "(cd $src_dir && patch -N -p1 < $patch)"
    done

    # Apply the CODE-* patches
    patches=$(ls "${PATCHES_DIR}/${DIST}/${name}/CODE-"*.patch 2>/dev/null)
    for patch in $patches; do
        patch=$(readlink -e $patch)
        run_in_dir $src_dir quilt import $patch
        run_in_dir $src_dir quilt push
        #(cd $src_dir; quilt import $patch && quilt push)
    done
done

# Build packages
for name in $pkgs; do
    src_dir=$(get_src_dir $name)

    conf=$(readlink -e "$PBUILDER_CONF")
    run mkdir -p "$BUILDRESULT"
    run rm -f "$BUILDRESULT/${name}_"*.deb

    run_in_dir $src_dir pdebuild --configfile $conf --use-pdebuild-internal
done

# Clean up
run cd ../ # Get out of the $BUILD_DIR directory
run rm -rf $BUILD_DIR
