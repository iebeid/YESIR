# --- Step 0: Preparation ---
echo "--- Updating apt and installing necessary tools (gdisk, mdadm, lvm2, xfsprogs) ---"
apt update
apt install -y gdisk mdadm lvm2 xfsprogs # xfsprogs for XFS filesystem

echo "--- Verifying disk devices. This is crucial! ---"
sudo lsblk -o NAME,SIZE,TYPE,ROTA,MODEL,WWN,VENDOR,SERIAL
sudo fdisk -l

echo "--- PLEASE CONFIRM YOUR DRIVES: ---"
echo "--- OS Drive: /dev/nvme0n1 (~1.9T) ---"
echo "--- RAID Member 1: /dev/nvme1n1 (~1.9T) ---"
echo "--- RAID Member 2: /dev/nvme2n1 (~1.9T) ---"
echo "--- RAID Member 3: /dev/nvme3n1 (~1.9T) ---"
echo "--- RAID Member 4: /dev/sda (~1.7T) ---"
echo "--- Your USB Installer: Likely /dev/sdb (should be small, e.g., 7.5G) ---"
echo "--- If these are not correct, STOP NOW AND DO NOT PROCEED! ---"
echo "Press Enter to continue..."
read # Wait for user to press Enter

# --- Step 1: Aggressive Disk Wipe ---
echo "--- WARNING: Wiping ALL 5 main drives. This is irreversible and takes time. ---"
echo "--- Press Ctrl+C in 15 seconds to abort, otherwise it will proceed. ---"
sleep 15

# Loop through all 5 drives
for DRV in /dev/nvme0n1 /dev/nvme1n1 /dev/nvme2n1 /dev/nvme3n1 /dev/sda; do
    echo "--- Wiping beginning of $DRV with zeroes (100MB) ---"
    sudo dd if=/dev/zero of=$DRV bs=1M count=100 status=progress || true # || true to ignore dd errors if device busy

    echo "--- Zeroing mdadm superblocks on $DRV ---"
    sudo mdadm --zero-superblock $DRV || true # || true to ignore errors if no superblock

    echo "--- Wiping all filesystem and partition signatures on $DRV ---"
    sudo wipefs -a $DRV || true # || true to ignore errors if no signature
done

echo "--- Aggressive wipe complete. Now rebooting to clear kernel state. ---"
echo "--- Boot back into installer TTY after reboot. ---"
# Do NOT try to proceed without rebooting after this wipe.
reboot
exit # Exit root shell to let reboot happen

# --- Step 2: Partition OS Drive (/dev/nvme0n1) ---
echo "--- Partitioning /dev/nvme0n1 for OS components ---"
DRV_OS="/dev/nvme0n1"

# 1. EFI System Partition (ESP) - 1GB
sudo sgdisk --new=1:0:+1024MiB ${DRV_OS} \
             --typecode=1:ef00 ${DRV_OS} \
             --change-name=1:"EFI System Partition" ${DRV_OS}

# 2. Swap Space - 8GB
sudo sgdisk --new=2:0:+8192MiB ${DRV_OS} \
             --typecode=2:8200 ${DRV_OS} \
             --change-name=2:"Linux Swap" ${DRV_OS}

# 3. Root Filesystem (/) - 500GB
sudo sgdisk --new=3:0:+500G ${DRV_OS} \
             --typecode=3:8300 ${DRV_OS} \
             --change-name=3:"Linux Root" ${DRV_OS}

# 4. Leave remaining space unallocated for now.

echo "--- Partitioning of ${DRV_OS} complete. ---"
sudo lsblk ${DRV_OS}

# --- Step 3: Format OS Drive Partitions ---
echo "--- Formatting OS drive partitions ---"

# Format ESP (FAT32)
sudo mkfs.fat -F 32 -n "EFI_SYSTEM" ${DRV_OS}p1

# Format Swap
sudo mkswap -L "SWAP" ${DRV_OS}p2

# Format Root (Ext4)
sudo mkfs.ext4 -F -L "ROOT" ${DRV_OS}p3

echo "--- OS drive partitions formatted. ---"

# --- Step 4: Partition RAID Member Drives ---
echo "--- Partitioning RAID member drives for Software RAID5 ---"
RAID_MEMBERS="/dev/nvme1n1 /dev/nvme2n1 /dev/nvme3n1 /dev/sda"
PART_NUM=1 # Assuming we create partition 1 on each drive

for DRV in ${RAID_MEMBERS}; do
    echo "--- Partitioning ${DRV} for RAID ---"
    # Create one partition spanning the entire drive, type Linux RAID Autodetect (fd00)
    sudo sgdisk --new=${PART_NUM}:0:0 ${DRV} \
                 --typecode=${PART_NUM}:fd00 ${DRV} \
                 --change-name=${PART_NUM}:"Linux RAID" ${DRV}
done

echo "--- RAID member partitioning complete. ---"
sudo lsblk ${RAID_MEMBERS}

# --- Step 5: Create Software RAID5 Array ---
echo "--- Creating Software RAID5 array /dev/md0 ---"
# Check partition names again, typically p1 suffix after sgdisk
RAID_PARTITIONS="/dev/nvme1n1p1 /dev/nvme2n1p1 /dev/nvme3n1p1 /dev/sda1"

# Force creation (-f) and assume clean array (-c)
sudo mdadm --create /dev/md0 --level=5 --raid-devices=4 ${RAID_PARTITIONS} --force --assume-clean

echo "--- RAID array /dev/md0 creation started. Check sync status: cat /proc/mdstat ---"
echo "--- It will take a long time to sync. Installer can proceed while syncing. ---"
cat /proc/mdstat

# --- Step 6: Create LVM on RAID5 Array ---
echo "--- Creating LVM Physical Volume on /dev/md0 ---"
sudo pvcreate /dev/md0

echo "--- Creating LVM Volume Group 'data-vg' ---"
sudo vgcreate data-vg /dev/md0

echo "--- Creating Logical Volumes within 'data-vg' ---"
# /home (100GB)
sudo lvcreate -L 100G -n home data-vg

# /var (250GB)
sudo lvcreate -L 250G -n var data-vg

# /srv (250GB)
sudo lvcreate -L 250G -n srv data-vg

# /opt (50GB)
sudo lvcreate -L 50G -n opt data-vg

# /tmp (20GB)
sudo lvcreate -L 20G -n tmp data-vg

# /data (Remaining space)
sudo lvcreate -l 100%FREE -n data data-vg

echo "--- Logical Volumes created. ---"
sudo lvs -o lv_path,lv_size,lv_name,vg_name

# --- Step 7: Format Logical Volumes ---
echo "--- Formatting Logical Volumes ---"

# Format /home (Ext4)
sudo mkfs.ext4 -F -L "HOME" /dev/mapper/data-vg-home

# Format /var (Ext4)
sudo mkfs.ext4 -F -L "VAR" /dev/mapper/data-vg-var

# Format /srv (Ext4)
sudo mkfs.ext4 -F -L "SRV" /dev/mapper/data-vg-srv

# Format /opt (Ext4)
sudo mkfs.ext4 -F -L "OPT" /dev/mapper/data-vg-opt

# Format /tmp (Ext4)
sudo mkfs.ext4 -F -L "TMP" /dev/mapper/data-vg-tmp

# Format /data (XFS)
sudo mkfs.xfs -f -L "DATA" /dev/mapper/data-vg-data

echo "--- All Logical Volumes formatted. ---"


