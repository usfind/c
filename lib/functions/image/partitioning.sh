#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0
#
# Copyright (c) 2013-2023 Igor Pecovnik, igor@armbian.com
#
# This file is a part of the Armbian Build Framework
# https://github.com/armbian/build/

# prepare_partitions
#
# creates image file, partitions and fs
# and mounts it to local dir
# FS-dependent stuff (boot and root fs partition types) happens here
#
# LOGGING: this is run under the log manager. so just redirect unwanted stderr to stdout, and it goes to log.
# this is under the logging manager. so just log to stdout (no redirections), and redirect stderr to stdout unless you want it on screen.
function prepare_partitions() {
	display_alert "Preparing image file for rootfs" "$BOARD $RELEASE" "info"

	# possible partition combinations
	# /boot: none, ext4, ext2, fat (BOOTFS_TYPE)
	# root: ext4, btrfs, f2fs, nilfs2, nfs (ROOTFS_TYPE)

	# declare makes local variables by default if used inside a function
	# NOTE: mountopts string should always start with comma if not empty

	# array copying in old bash versions is tricky, so having filesystems as arrays
	# with attributes as keys is not a good idea
	declare -A parttype mkopts mkopts_label mkfs mountopts

	parttype[ext4]=ext4
	parttype[ext2]=ext2
	parttype[fat]=fat16
	parttype[f2fs]=ext4 # not a copy-paste error
	parttype[btrfs]=btrfs
	parttype[nilfs2]=nilfs2
	parttype[xfs]=xfs
	# parttype[nfs] is empty

	mkopts[ext4]="-q -m 2" # for a long time we had '-O ^64bit,^metadata_csum' here
	# Hack: newer versions of e2fsprogs in combination with recent kernels enable orphan_file (FEATURE_C12) by default; that can't be handled by older versions of e2fsprogs
	#       at the same time, older versions don't know about orphan_file at all, so we can't simply disable for all.
	# run & parse the version of e2fsprogs to determine if we need to disable orphan_file
	declare e2fsprogs_version
	e2fsprogs_version=$(e2fsck -V 2>&1 | head -1 | cut -d " " -f 2 | xargs echo -n)
	# use linux-version compare to check if the version is at least 1.47
	if linux-version compare "${e2fsprogs_version}" ge "1.47"; then
		display_alert "e2fsprogs version" "$e2fsprogs_version supports orphan_file" "info"
		mkopts[ext4]="-q -m 2 -O ^orphan_file"
	else
		display_alert "e2fsprogs version" "$e2fsprogs_version does not support orphan_file" "info"
	fi

	# mkopts[fat] is empty
	# mkopts[ext2] is empty
	# mkopts[f2fs] is empty
	mkopts[btrfs]='-m dup' # '-m dup' is already the default https://man.archlinux.org/man/mkfs.btrfs.8#m_
	# mkopts[nilfs2] is empty
	# mkopts[xfs] is empty
	# mkopts[nfs] is empty

	mkopts_label[ext4]='-L '
	mkopts_label[ext2]='-L '
	mkopts_label[fat]='-n '
	mkopts_label[f2fs]='-l '
	mkopts_label[btrfs]='-L '
	mkopts_label[nilfs2]='-L '
	mkopts_label[xfs]='-L '
	# mkopts_label[nfs] is empty

	mkfs[ext4]=ext4
	mkfs[ext2]=ext2
	mkfs[fat]=vfat
	mkfs[f2fs]=f2fs
	mkfs[btrfs]=btrfs
	mkfs[nilfs2]=nilfs2
	mkfs[xfs]=xfs
	# mkfs[nfs] is empty

	mountopts[ext4]=',commit=120,errors=remount-ro' # EXT4 default: 5 (https://www.man7.org/linux/man-pages/man5/ext4.5.html)
	# mountopts[ext2] is empty
	# mountopts[fat] is empty
	# mountopts[f2fs] is empty
	mountopts[btrfs]=',commit=120' # BTRFS default: 30 (https://btrfs.readthedocs.io/en/latest/ch-mount-options.html)
	# mountopts[nilfs2] is empty
	# mountopts[xfs] is empty
	# mountopts[nfs] is empty

	# default BOOTSIZE to use if not specified
	DEFAULT_BOOTSIZE=256 # MiB
	SECTOR_SIZE=${SECTOR_SIZE:-512}
	# size of UEFI partition. 0 for no UEFI. Don't mix UEFISIZE>0 and BOOTSIZE>0
	UEFISIZE=${UEFISIZE:-0}
	BIOSSIZE=${BIOSSIZE:-0}
	UEFI_MOUNT_POINT=${UEFI_MOUNT_POINT:-/boot/efi}
	UEFI_FS_LABEL="${UEFI_FS_LABEL:-armbi_efi}"
	ROOT_FS_LABEL="${ROOT_FS_LABEL:-armbi_root}"
	BOOT_FS_LABEL="${BOOT_FS_LABEL:-armbi_boot}"

	call_extension_method "pre_prepare_partitions" "prepare_partitions_custom" <<- 'PRE_PREPARE_PARTITIONS'
		*allow custom options for mkfs*
		Good time to change stuff like mkfs opts, types etc.
	PRE_PREPARE_PARTITIONS

	# stage: determine partition configuration
	local next=1
	# Check if we need UEFI partition
	if [[ $UEFISIZE -gt 0 ]]; then
		# Check if we need BIOS partition
		[[ $BIOSSIZE -gt 0 ]] && local biospart=$((next++))
		local uefipart=$((next++))
	fi
	# Check if we need boot partition
	# Specialized storage extensions like cryptroot or lvm may require a boot partition
	if [[ $BOOTSIZE != "0" && (-n $BOOTFS_TYPE || $ROOTFS_TYPE != ext4 || $BOOTPART_REQUIRED == yes) ]]; then
		local bootpart=$((next++))
		local bootfs=${BOOTFS_TYPE:-ext4}
		[[ -z $BOOTSIZE || $BOOTSIZE -le 8 ]] && BOOTSIZE=${DEFAULT_BOOTSIZE}
	else
		BOOTSIZE=0
	fi
	# Check if we need root partition
	[[ $ROOTFS_TYPE != nfs ]] &&
		local rootpart=$((next++))

	display_alert "calculated rootpart" "rootpart: ${rootpart}" "debug"

	# stage: calculate rootfs size
	declare -g -i rootfs_size
	rootfs_size=$(du --apparent-size -sm "${SDCARD}"/ | cut -f1) # MiB
	display_alert "Current rootfs size" "$rootfs_size MiB" "info"

	call_extension_method "prepare_image_size" "config_prepare_image_size" <<- 'PREPARE_IMAGE_SIZE'
		*allow dynamically determining the size based on the $rootfs_size*
		Called after `${rootfs_size}` is known, but before `${FIXED_IMAGE_SIZE}` is taken into account.
		A good spot to determine `FIXED_IMAGE_SIZE` based on `rootfs_size`.
		UEFISIZE can be set to 0 for no UEFI partition, or to a size in MiB to include one.
		Last chance to set `USE_HOOK_FOR_PARTITION`=yes and then implement create_partition_table hook_point.
	PREPARE_IMAGE_SIZE

	local sdsize
	if [[ -n $FIXED_IMAGE_SIZE && $FIXED_IMAGE_SIZE =~ ^[0-9]+$ ]]; then
		display_alert "Using user-defined image size" "$FIXED_IMAGE_SIZE MiB" "info"
		sdsize=$FIXED_IMAGE_SIZE
		# basic sanity check
		if [[ $ROOTFS_TYPE != nfs && $ROOTFS_TYPE != btrfs && $sdsize -lt $rootfs_size ]]; then
			exit_with_error "User defined image size is too small" "$sdsize <= $rootfs_size"
		fi
	else
		local imagesize=$(($rootfs_size + $OFFSET + $BOOTSIZE + $UEFISIZE + $EXTRA_ROOTFS_MIB_SIZE)) # MiB
		# Hardcoded overhead +25% is needed for desktop images,
		# for CLI it could be lower. Align the size up to 4MiB
		if [[ $BUILD_DESKTOP == yes ]]; then
			sdsize=$(bc -l <<< "scale=0; ((($imagesize * 1.35) / 1 + 0) / 4 + 1) * 4")
		else
			sdsize=$(bc -l <<< "scale=0; ((($imagesize * 1.30) / 1 + 0) / 4 + 1) * 4")
		fi
	fi

	# stage: create blank image
	display_alert "Creating blank image for rootfs" "truncate: $sdsize MiB" "info"
	run_host_command_logged truncate "--size=${sdsize}M" "${SDCARD}".raw # please provide EVIDENCE of problems with this; using dd is very slow
	wait_for_disk_sync "after truncate SDCARD.raw"

	# stage: calculate boot partition size
	local bootstart=$(($OFFSET * 2048))
	local rootstart=$(($bootstart + ($BOOTSIZE * 2048) + ($UEFISIZE * 2048)))
	local bootend=$(($rootstart - 1))

	# stage: create partition table
	display_alert "Creating partitions" "${bootfs:+/boot: $bootfs }root: $ROOTFS_TYPE" "info"
	if [[ "${USE_HOOK_FOR_PARTITION}" == "yes" ]]; then
		{ [[ "$IMAGE_PARTITION_TABLE" == "msdos" ]] && echo "label: dos" || echo "label: $IMAGE_PARTITION_TABLE"; } |
			run_host_command_logged sfdisk "${SDCARD}".raw || exit_with_error "Create partition table fail"

		call_extension_method "create_partition_table" <<- 'CREATE_PARTITION_TABLE'
			*only called when USE_HOOK_FOR_PARTITION=yes to create the complete partition table*
			Finally, we can get our own partition table. You have to partition ${SDCARD}.raw
			yourself. Good luck.
		CREATE_PARTITION_TABLE
	else
		# Create a script in a bracket shell, then use the output of the script in sfdisk.
		partition_script_output=$(
			{
				[[ "$IMAGE_PARTITION_TABLE" == "msdos" ]] && echo "label: dos" || echo "label: $IMAGE_PARTITION_TABLE"

				local next=$OFFSET

				# Legacy BIOS partition
				if [[ -n "$biospart" ]]; then
					# gpt: BIOS boot
					[[ "$IMAGE_PARTITION_TABLE" != "gpt" ]] && exit_with_error "Legacy BIOS partition is not allowed for MBR partition table (${BIOSSIZE} can't be >0)!"
					local type="21686148-6449-6E6F-744E-656564454649"
					echo "$biospart : name=\"bios\", start=${next}MiB, size=${BIOSSIZE}MiB, type=${type}"
					local next=$(($next + $BIOSSIZE))
				fi

				# EFI partition
				if [[ -n "$uefipart" ]]; then
					# dos: EFI (FAT-12/16/32)
					# gpt: EFI System
					[[ "$IMAGE_PARTITION_TABLE" != "gpt" ]] && local type="ef" || local type="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
					echo "$uefipart : name=\"efi\", start=${next}MiB, size=${UEFISIZE}MiB, type=${type}"
					local next=$(($next + $UEFISIZE))
				fi

				# Linux extended boot loader (XBOOTLDR) partition
				# See also https://wiki.archlinux.org/title/Partitioning#/boot
				if [[ -n "$bootpart" ]]; then
					# dos: Linux extended boot (see https://github.com/util-linux/util-linux/commit/d0c430068206e1215222792e3aa10689f8c632a6)
					# gpt: Linux extended boot
					[[ "$IMAGE_PARTITION_TABLE" != "gpt" ]] && local type="ea" || local type="BC13C2FF-59E6-4262-A352-B275FD6F7172"
					if [[ -n "$rootpart" ]]; then
						echo "$bootpart : name=\"bootfs\", start=${next}MiB, size=${BOOTSIZE}MiB, type=${type}"
						local next=$(($next + $BOOTSIZE))
					else
						# No 'size' argument means "expand as much as possible"
						echo "$bootpart : name=\"bootfs\", start=${next}MiB, type=${type}"
					fi
				fi

				# Root filesystem partition
				if [[ -n "$rootpart" ]]; then
					# dos: Linux
					# gpt: Linux root
					if [[ "$IMAGE_PARTITION_TABLE" != "gpt" ]]; then
						local type="83"
					else
						# Linux root has a different Type-UUID for every architecture
						# See https://uapi-group.org/specifications/specs/discoverable_partitions_specification/
						# The ${PARTITION_TYPE_UUID_ROOT} variable is defined in each architecture file (e.g. config/sources/arm64.conf)
						if [[ -n "${PARTITION_TYPE_UUID_ROOT}" ]]; then
							local type="${PARTITION_TYPE_UUID_ROOT}"
						else
							exit_with_error "Missing 'PARTITION_TYPE_UUID_ROOT' variable while partitioning the root filesystem!"
						fi
					fi
					# No 'size' argument means "expand as much as possible"
					echo "$rootpart : name=\"rootfs\", start=${next}MiB, type=${type}"
				fi
			}
		)
		# Output the partitioning options from above to the debug log first and then pipe it into the 'sfdisk' command
		display_alert "Partitioning with the following options" "$partition_script_output" "debug"

		# Check sfdisk version to determine if --sector-size is supported
		sfdisk_version=$(sfdisk --version | awk '/util-linux/ {print $NF}')
		sfdisk_version_num=$(echo "$sfdisk_version" | awk -F. '{printf "%d%02d%02d\n", $1, $2, $3}')
		if [ "$sfdisk_version_num" -ge "24100" ]; then
			echo "${partition_script_output}" | run_host_command_logged sfdisk --sector-size "$SECTOR_SIZE" "${SDCARD}".raw || exit_with_error "Partitioning failed!"
		else
			echo "${partition_script_output}" | run_host_command_logged sfdisk "${SDCARD}".raw || exit_with_error "Partitioning failed!"
		fi

	fi

	call_extension_method "post_create_partitions" <<- 'POST_CREATE_PARTITIONS'
		*called after all partitions are created, but not yet formatted*
	POST_CREATE_PARTITIONS

	# stage: mount image
	# lock access to loop devices
	exec {FD}> /var/lock/armbian-debootstrap-losetup
	flock -x $FD

	declare -g LOOP
	#--partscan is using to force the kernel for scaning partition table in preventing of partprobe errors
	if [ "$sfdisk_version_num" -ge "24100" ]; then
		LOOP=$(losetup --show --partscan --find -b "$SECTOR_SIZE" "${SDCARD}".raw) || exit_with_error "Unable to find free loop device"
	else
		LOOP=$(losetup --show --partscan --find "${SDCARD}".raw) || exit_with_error "Unable to find free loop device"
	fi
	display_alert "Allocated loop device" "LOOP=${LOOP}"

	# loop device was grabbed here, unlock
	flock -u $FD

	display_alert "Running partprobe" "${LOOP}" "debug"
	run_host_command_logged partprobe "${LOOP}"

	display_alert "Checking again after partprobe" "${LOOP}" "debug"
	check_loop_device "${LOOP}" # check again, now it has to have a size! otherwise wait.

	# stage: create fs, mount partitions, create fstab
	rm -f $SDCARD/etc/fstab

	declare root_part_uuid="uninitialized"

	##
	## ROOT PARTITION
	##
	if [[ -n $rootpart ]]; then
		local rootdevice=${LOOP}p${rootpart}
		local physical_rootdevice=$rootdevice

		call_extension_method "prepare_root_device" <<- 'PREPARE_ROOT_DEVICE'
			*Specialized storage extensions typically transform the root device into a mapped device and should hook in here *
			At this stage ${rootdevice} has been defined pointing to a loop device partition. Extensions that map the root device must update rootdevice accordingly.
		PREPARE_ROOT_DEVICE

		check_loop_device "$rootdevice"
		display_alert "Creating rootfs" "$ROOTFS_TYPE on $rootdevice"
		run_host_command_logged mkfs.${mkfs[$ROOTFS_TYPE]} ${mkopts[$ROOTFS_TYPE]} ${mkopts_label[$ROOTFS_TYPE]:+${mkopts_label[$ROOTFS_TYPE]}"$ROOT_FS_LABEL"} "${rootdevice}"

		#
		# BEGIN: Options for specific filesystems
		[[ $ROOTFS_TYPE == ext4 ]] && run_host_command_logged tune2fs -o journal_data_writeback "$rootdevice"
		if [[ $ROOTFS_TYPE == btrfs && $BTRFS_COMPRESSION != none ]]; then
			local fscreateopt="-o compress-force=${BTRFS_COMPRESSION}"
		fi
		# END: Options for specific filesystems
		#

		wait_for_disk_sync "after mkfs" # force writes to be really flushed

		# store in readonly global for usage in later hooks
		root_part_uuid="$(blkid -s UUID -o value ${LOOP}p${rootpart})"
		declare -g -r ROOT_PART_UUID="${root_part_uuid}"

		display_alert "Mounting rootfs" "$rootdevice (UUID=${ROOT_PART_UUID})"
		run_host_command_logged mount ${fscreateopt} $rootdevice $MOUNT/

		# create fstab (and crypttab) entry
		if [[ $CRYPTROOT_ENABLE == yes ]]; then
			# map the LUKS container partition via its UUID to be the 'cryptroot' device
			physical_root_part_uuid="$(blkid -s UUID -o value $physical_rootdevice)"
			echo "$CRYPTROOT_MAPPER UUID=${physical_root_part_uuid} none luks" >> $SDCARD/etc/crypttab
			run_host_command_logged cat $SDCARD/etc/crypttab
		fi

		if [[ $ROOTFS_TYPE == btrfs ]]; then
			mountopts[$ROOTFS_TYPE]='commit=120'
			run_host_command_logged btrfs subvolume create $MOUNT/@
			# getting the subvolume id of the newly created volume @ to install it
			# as the default volume for mounting without explicit reference

			run_host_command_logged "btrfs subvolume list $MOUNT | grep 'path @' | cut -d' ' -f2 \
				| xargs -I{} btrfs subvolume set-default {} $MOUNT/ "

			call_extension_method "btrfs_root_add_subvolumes" <<- 'BTRFS_ROOT_ADD_SUBVOLUMES'
				# *custom post btrfs rootfs creation hook*
				# Called if rootfs btrfs after creating the subvolume "@" for rootfs
				# Used to create other separate btrfs subvolume if needed.
				# Mountpoints and fstab records should be created too.
				run_host_command_logged btrfs subvolume create $MOUNT/@home
				run_host_command_logged btrfs subvolume create $MOUNT/@var
				run_host_command_logged btrfs subvolume create $MOUNT/@var_log
				run_host_command_logged btrfs subvolume create $MOUNT/@var_cache
				run_host_command_logged btrfs subvolume create $MOUNT/@srv
			BTRFS_ROOT_ADD_SUBVOLUMES

			run_host_command_logged umount $rootdevice
			display_alert "Remounting rootfs" "$rootdevice (UUID=${ROOT_PART_UUID})"
			run_host_command_logged mount -odefaults,${mountopts[$ROOTFS_TYPE]},subvol=@ $rootdevice $MOUNT/
		fi
		rootfs="UUID=$(blkid -s UUID -o value $rootdevice)"
		echo "$rootfs / ${mkfs[$ROOTFS_TYPE]} defaults,${mountopts[$ROOTFS_TYPE]} 0 1" >> $SDCARD/etc/fstab
		if [[ $ROOTFS_TYPE == btrfs ]]; then
			call_extension_method "btrfs_root_add_subvolumes_fstab" <<- 'BTRFS_ROOT_ADD_SUBVOLUMES_FSTAB'
				run_host_command_logged mkdir -p $MOUNT/home
				run_host_command_logged mount -odefaults,${mountopts[$ROOTFS_TYPE]},subvol=@home $rootdevice $MOUNT/home
				echo "$rootfs /home btrfs defaults,${mountopts[$ROOTFS_TYPE]},subvol=@home 0 2" >> $SDCARD/etc/fstab
				run_host_command_logged mkdir -p $MOUNT/var
				run_host_command_logged mount -odefaults,${mountopts[$ROOTFS_TYPE]},subvol=@var $rootdevice $MOUNT/var
				echo "$rootfs /var btrfs defaults,${mountopts[$ROOTFS_TYPE]},subvol=@var 0 2" >> $SDCARD/etc/fstab
				run_host_command_logged mkdir -p $MOUNT/var/log
				run_host_command_logged mount -odefaults,${mountopts[$ROOTFS_TYPE]},subvol=@var_log $rootdevice $MOUNT/var/log
				echo "$rootfs /var/log btrfs defaults,${mountopts[$ROOTFS_TYPE]},subvol=@var_log 0 2" >> $SDCARD/etc/fstab
				run_host_command_logged mkdir -p $MOUNT/var/cache
				run_host_command_logged mount -odefaults,${mountopts[$ROOTFS_TYPE]},subvol=@var_cache $rootdevice $MOUNT/var/cache
				echo "$rootfs /var/cache btrfs defaults,${mountopts[$ROOTFS_TYPE]},subvol=@var_cache 0 2" >> $SDCARD/etc/fstab
				run_host_command_logged mkdir -p  $MOUNT/srv
				run_host_command_logged mount -odefaults,${mountopts[$ROOTFS_TYPE]},subvol=@srv $rootdevice $MOUNT/srv
				echo "$rootfs /srv btrfs defaults,${mountopts[$ROOTFS_TYPE]},subvol=@srv 0 2" >> $SDCARD/etc/fstab
			BTRFS_ROOT_ADD_SUBVOLUMES_FSTAB
		fi

		run_host_command_logged cat $SDCARD/etc/fstab

	else
		# update_initramfs will fail if /lib/modules/ doesn't exist
		mount --bind --make-private $SDCARD $MOUNT/
		echo "/dev/nfs / nfs defaults 0 0" >> $SDCARD/etc/fstab
	fi

	##
	## BOOT (XBOOTLDR) PARTITION
	##
	if [[ -n $bootpart ]]; then
		display_alert "Creating /boot" "$bootfs on ${LOOP}p${bootpart}"
		check_loop_device "${LOOP}p${bootpart}"
		run_host_command_logged mkfs.${mkfs[$bootfs]} ${mkopts[$bootfs]} ${mkopts_label[$bootfs]:+${mkopts_label[$bootfs]}"$BOOT_FS_LABEL"} ${LOOP}p${bootpart}
		mkdir -p $MOUNT/boot/
		run_host_command_logged mount ${LOOP}p${bootpart} $MOUNT/boot/
		echo "UUID=$(blkid -s UUID -o value ${LOOP}p${bootpart}) /boot ${mkfs[$bootfs]} defaults${mountopts[$bootfs]} 0 2" >> $SDCARD/etc/fstab
	fi

	##
	## EFI PARTITION
	##
	if [[ -n $uefipart ]]; then
		display_alert "Creating EFI partition" "FAT32 ${UEFI_MOUNT_POINT} on ${LOOP}p${uefipart} label ${UEFI_FS_LABEL}"
		check_loop_device "${LOOP}p${uefipart}"
		run_host_command_logged mkfs.fat -F32 -n "${UEFI_FS_LABEL^^}" ${LOOP}p${uefipart} 2>&1 # "^^" makes variable UPPERCASE, required for FAT32.
		mkdir -p "${MOUNT}${UEFI_MOUNT_POINT}"
		run_host_command_logged mount ${LOOP}p${uefipart} "${MOUNT}${UEFI_MOUNT_POINT}"

		# Allow skipping the fstab entry for the EFI partition if UEFI_MOUNT_POINT_SKIP_FSTAB=yes; add comments instead if so
		if [[ "${UEFI_MOUNT_POINT_SKIP_FSTAB:-"no"}" == "yes" ]]; then
			display_alert "Skipping EFI partition in fstab" "UEFI_MOUNT_POINT_SKIP_FSTAB=${UEFI_MOUNT_POINT_SKIP_FSTAB}" "debug"
			echo "# /boot/efi fstab commented out due to UEFI_MOUNT_POINT_SKIP_FSTAB=${UEFI_MOUNT_POINT_SKIP_FSTAB}"
			echo "# UUID=$(blkid -s UUID -o value ${LOOP}p${uefipart}) ${UEFI_MOUNT_POINT} vfat defaults 0 2" >> $SDCARD/etc/fstab
		else
			echo "UUID=$(blkid -s UUID -o value ${LOOP}p${uefipart}) ${UEFI_MOUNT_POINT} vfat defaults 0 2" >> $SDCARD/etc/fstab
		fi
	fi
	##
	## END OF PARTITION CREATION
	##

	display_alert "Writing /tmp as tmpfs in chroot fstab" "$SDCARD/etc/fstab" "debug"
	echo "tmpfs /tmp tmpfs defaults,nosuid 0 0" >> $SDCARD/etc/fstab

	call_extension_method "format_partitions" <<- 'FORMAT_PARTITIONS'
		*if you created your own partitions, this would be a good time to format them*
		The loop device is mounted, so ${LOOP}p1 is it's first partition etc.
	FORMAT_PARTITIONS

	# stage: adjust boot script or boot environment
	if [[ -f $SDCARD/boot/armbianEnv.txt ]]; then
		display_alert "Found armbianEnv.txt" "${SDCARD}/boot/armbianEnv.txt" "debug"
		if [[ $CRYPTROOT_ENABLE == yes ]]; then
			echo "rootdev=$rootdevice cryptdevice=UUID=${physical_root_part_uuid}:$CRYPTROOT_MAPPER" >> "${SDCARD}/boot/armbianEnv.txt"
		else
			echo "rootdev=$rootfs" >> "${SDCARD}/boot/armbianEnv.txt"
		fi
		echo "rootfstype=$ROOTFS_TYPE" >> $SDCARD/boot/armbianEnv.txt
	elif [[ $rootpart != 1 ]] && [[ $SRC_EXTLINUX != yes ]]; then
		echo "rootfstype=$ROOTFS_TYPE" >> "${SDCARD}/boot/armbianEnv.txt"
	elif [[ $rootpart != 1 && $SRC_EXTLINUX != yes && -f "${SDCARD}/boot/${bootscript_dst}" ]]; then
		local bootscript_dst=${BOOTSCRIPT##*:}
		sed -i 's/mmcblk0p1/mmcblk0p2/' $SDCARD/boot/$bootscript_dst
		sed -i -e "s/rootfstype=ext4/rootfstype=$ROOTFS_TYPE/" \
			-e "s/rootfstype \"ext4\"/rootfstype \"$ROOTFS_TYPE\"/" $SDCARD/boot/$bootscript_dst
	fi

	# if we have boot.ini = remove armbianEnv.txt and add UUID there if enabled
	if [[ -f $SDCARD/boot/boot.ini ]]; then
		display_alert "Found boot.ini" "${SDCARD}/boot/boot.ini" "debug"
		sed -i -e "s/rootfstype \"ext4\"/rootfstype \"$ROOTFS_TYPE\"/" $SDCARD/boot/boot.ini
		if [[ $CRYPTROOT_ENABLE == yes ]]; then
			rootpart="UUID=${physical_root_part_uuid}"
			sed -i 's/^setenv rootdev .*/setenv rootdev "\/dev\/mapper\/'$CRYPTROOT_MAPPER' cryptdevice='$rootpart':'$CRYPTROOT_MAPPER'"/' $SDCARD/boot/boot.ini
		else
			sed -i 's/^setenv rootdev .*/setenv rootdev "'$rootfs'"/' $SDCARD/boot/boot.ini
		fi
		if [[ $LINUXFAMILY != meson64 ]]; then # @TODO: why only for meson64?
			[[ -f $SDCARD/boot/armbianEnv.txt ]] && rm $SDCARD/boot/armbianEnv.txt
		fi
	fi

	# if we have a headless device, set console to DEFAULT_CONSOLE
	if [[ -n $DEFAULT_CONSOLE && -f $SDCARD/boot/armbianEnv.txt ]]; then
		if grep -lq "^console=" $SDCARD/boot/armbianEnv.txt; then
			sed -i "s/^console=.*/console=$DEFAULT_CONSOLE/" $SDCARD/boot/armbianEnv.txt
		else
			echo "console=$DEFAULT_CONSOLE" >> $SDCARD/boot/armbianEnv.txt
		fi
	fi

	# recompile .cmd to .scr if boot.cmd exists
	if [[ -f "${SDCARD}/boot/boot.cmd" ]]; then
		if [ -z ${BOOTSCRIPT_OUTPUT} ]; then
			BOOTSCRIPT_OUTPUT=boot.scr
		fi
		case ${LINUXFAMILY} in
			x86)
				:
				display_alert "Compiling boot.scr" "boot/${BOOTSCRIPT_OUTPUT} x86" "debug"
				run_host_command_logged cat "${SDCARD}/boot/boot.cmd"
				run_host_command_logged mkimage -T script -C none -n "'Boot script'" -d "${SDCARD}/boot/boot.cmd" "${SDCARD}/boot/${BOOTSCRIPT_OUTPUT}"
				;;
			*)
				display_alert "Compiling boot.scr" "boot/${BOOTSCRIPT_OUTPUT} ARM" "debug"
				run_host_command_logged mkimage -C none -A arm -T script -d "${SDCARD}/boot/boot.cmd" "${SDCARD}/boot/${BOOTSCRIPT_OUTPUT}"
				;;
		esac
	fi

	# complement extlinux config if it exists; remove armbianEnv in this case.
	if [[ -f $SDCARD/boot/extlinux/extlinux.conf ]]; then
		echo "  append root=$rootfs $SRC_CMDLINE $MAIN_CMDLINE" >> $SDCARD/boot/extlinux/extlinux.conf
		display_alert "extlinux.conf exists" "removing armbianEnv.txt" "info"
		[[ -f $SDCARD/boot/armbianEnv.txt ]] && run_host_command_logged rm -v $SDCARD/boot/armbianEnv.txt
	fi

	if [[ $SRC_EXTLINUX != yes && -f $SDCARD/boot/armbianEnv.txt ]]; then
		call_extension_method "image_specific_armbian_env_ready" <<- 'IMAGE_SPECIFIC_ARMBIAN_ENV_READY'
			*during image build, armbianEnv.txt is ready for image-specific customization (not in BSP)*
			You can write to `"${SDCARD}/boot/armbianEnv.txt"` here, it is guaranteed to exist.
		IMAGE_SPECIFIC_ARMBIAN_ENV_READY
	fi

	return 0 # there is a shortcircuit above! very tricky btw!
}
