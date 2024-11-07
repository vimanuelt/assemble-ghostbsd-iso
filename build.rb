#!/usr/bin/env ruby

require 'fileutils'
require 'optparse'

CWD = Dir.pwd

# Only run as superuser
abort("This script must be run as root") unless Process.uid.zero?

KERNEL = `uname -r`.strip
SUPPORTED_KERNELS = ['13.3-STABLE', '14.1-STABLE', '15.0-CURRENT']

unless SUPPORTED_KERNELS.include?(KERNEL)
  puts "FreeBSD or GhostBSD release is not supported."
  exit 1
end

# Use `Dir.glob` to locate base files and extract filenames directly
desktop_list = Dir.glob('packages/*base*').map { |f| File.basename(f) }.join(' ')
desktop_config_list = Dir.glob('desktop_config/*')

def help_function
  puts <<~HELP
    Usage: #{__FILE__} -d desktop -r release type
        -h for help
        -d Desktop: #{desktop_list}
        -b Build type: unstable or release
        -t Test: FreeBSD os packages
  HELP
  exit 1
end

# Default options
desktop = "mate"
build_type = "release"

# Parse command-line options
OptionParser.new do |opts|
  opts.on('-d DESKTOP') { |v| desktop = v }
  opts.on('-b BUILD_TYPE') { |v| build_type = v }
  opts.on('-t') { desktop = "test"; build_type = "test" }
  opts.on('-h') { help_function }
end.parse!

PKG_CONF = case build_type
           when "test" then "FreeBSD"
           when "release" then "GhostBSD"
           when "unstable" then "GhostBSD_Unstable"
           else
             puts "\t-b Build type: unstable or release"
             exit 1
           end

# validate desktop packages
unless File.exist?("#{CWD}/packages/#{desktop}")
  puts "The packages/#{desktop} file does not exist."
  puts "Please create a package file named '#{desktop}' and place it under packages/."
  puts "Or use a valid desktop below:\n#{desktop_list}"
  exit 1
end

# validate desktop configuration
unless File.exist?("#{CWD}/desktop_config/#{desktop}.sh")
  puts "The desktop_config/#{desktop}.sh file does not exist."
  puts "Please create a config file named '#{desktop}.sh' like these config:\n#{desktop_config_list}"
  exit 1
end

community = desktop != "mate" ? "-#{desktop.upcase}" : ""

# Define directories
workdir = "/usr/local"
livecd = "#{workdir}/ghostbsd-build"
base = "#{livecd}/base"
iso = "#{livecd}/iso"
software_packages = "#{livecd}/software_packages"
base_packages = "#{livecd}/base_packages"
release = "#{livecd}/release"
release_path = "#{iso}/GhostBSD#{desktop}#{community}.iso"

def workspace
  # Clean up and setup directories
  system("umount #{software_packages} #{base_packages} #{release}/dev >/dev/null 2>/dev/null")
  system("zpool destroy ghostbsd >/dev/null 2>/dev/null")
  system("umount #{release} >/dev/null 2>/dev/null")

  FileUtils.rm_rf("#{livecd}/pool.img")
  FileUtils.rm_rf("#{CWD}/cd_root")
  Dir.mkdir(livecd)
end

def base
  # Set up base packages
  base_list = File.read("#{CWD}/packages/#{desktop == "test" ? "test_base" : "base"}")
  vital_base = File.read("#{CWD}/packages/vital/#{desktop == "test" ? "test_base" : "base"}")
  Dir.mkdir("#{release}/etc")
  FileUtils.cp('/etc/resolv.conf', "#{release}/etc/resolv.conf")
  Dir.mkdir("#{release}/var/cache/pkg")
  system("mount_nullfs #{base_packages} #{release}/var/cache/pkg")
  system("pkg-static -r #{release} -R #{CWD}/pkg/ install -y -r #{PKG_CONF}_base #{base_list}")
  system("pkg-static -r #{release} -R #{CWD}/pkg/ set -y -v 1 #{vital_base}")
  FileUtils.rm("#{release}/etc/resolv.conf")
  system("umount #{release}/var/cache/pkg")
end

def set_ghostbsd_version
  version = desktop == "test" ? Time.now.strftime("%Y-%m-%d") : `cat #{release}/etc/version`.strip
  iso_path = "#{iso}/GhostBSD#{version}#{community}.iso"
end

def packages_software
  FileUtils.cp("#{CWD}/pkg/GhostBSD_Unstable.conf", "#{release}/etc/pkg/GhostBSD.conf") if build_type == "unstable"
  FileUtils.cp('/etc/resolv.conf', "#{release}/etc/resolv.conf")
  system("mount_nullfs #{software_packages} #{release}/var/cache/pkg")
  system("mount -t devfs devfs #{release}/dev")
  packages = File.read("#{CWD}/packages/#{desktop}")
  vital_packages = File.read("#{CWD}/packages/vital/#{desktop}")
  system("pkg-static -c #{release} install -y #{packages}")
  system("pkg-static -c #{release} set -y -v 1 #{vital_packages}")
  FileUtils.rm("#{release}/etc/resolv.conf")
  system("umount #{release}/var/cache/pkg")
end

def fetch_x_drivers_packages
  pkg_url = if build_type == "release"
              `pkg-static -R #{CWD}/pkg/ -vv | grep '/stable.*/latest'`.strip.split('"')[1]
            else
              `pkg-static -R #{CWD}/pkg/ -vv | grep '/unstable.*/latest'`.strip.split('"')[1]
            end
  Dir.mkdir("#{release}/xdrivers")
  system("yes | pkg -R #{CWD}/pkg/ update")
  drivers_list = `pkg -R #{CWD}/pkg/ rquery -x -r #{PKG_CONF} '%n %n-%v.pkg' 'nvidia-driver' | grep -v libva`
  File.write("#{release}/xdrivers/drivers-list", drivers_list)
  drivers_list.each_line do |line|
    system("fetch -o #{release}/xdrivers #{pkg_url}/All/#{line.strip}")
  end
end

def rc
  # System configuration for live environment
  ["hostname='livecd'", "zfs_enable='YES'", "kld_list='linux linux64 cuse fusefs hgame'", 
   "linux_enable='YES'", "devfs_enable='YES'", "devfs_system_ruleset='devfsrules_common'",
   "moused_enable='YES'", "dbus_enable='YES'", "lightdm_enable='NO'", "webcamd_enable='YES'",
   "ipfw_enable='YES'", "firewall_enable='YES'", "cupsd_enable='YES'", "avahi_daemon_enable='YES'",
   "avahi_dnsconfd_enable='YES'", "ntpd_enable='YES'", "ntpd_sync_on_start='YES'"].each do |conf|
    system("chroot #{release} sysrc #{conf}")
  end
end

def ghostbsd_config
  Dir.mkdir("#{release}/usr/local/share/ghostbsd")
  File.write("#{release}/usr/local/share/ghostbsd/desktop", desktop)
  FileUtils.mv("#{release}/usr/local/etc/devd/automount_devd.conf", "#{release}/usr/local/etc/devd/automount_devd.conf.skip")
  FileUtils.mv("#{release}/usr/local/etc/devd/automount_devd_localdisks.conf", "#{release}/usr/local/etc/devd/automount_devd_localdisks.conf.skip")
  system("chroot #{release} mkdir -p /compat/linux/dev/shm")
  system("chroot #{release} touch /boot/entropy")
  system("chroot #{release} touch /etc/wall_cmos_clock")
end

def desktop_config
  system("sh #{CWD}/desktop_config/#{desktop}.sh")
end

def uzip
  cd_root = "#{CWD}/cd_root"
  Dir.mkdir(cd_root) unless Dir.exist?(cd_root)
  system("zfs snapshot ghostbsd@clean")
  system("zfs send -p -c -e ghostbsd@clean | dd of=#{cd_root}/data/system.img status=progress bs=1M")
end

def ramdisk
  ramdisk_root = "#{CWD}/cd_root/data/ramdisk"
  Dir.mkdir(ramdisk_root)
  FileUtils.cd(release) do
    system("tar -cf - rescue | tar -xf - -C #{ramdisk_root}")
  end
  FileUtils.install("init.sh.in", "#{ramdisk_root}/init.sh", mode: 0755, owner: 'root', group: 'wheel')
  Dir.mkdir("#{ramdisk_root}/dev")
  Dir.mkdir("#{ramdisk_root}/etc")
  FileUtils.touch("#{ramdisk_root}/etc/fstab")
  FileUtils.install("rc.in", "#{ramdisk_root}/etc/rc", mode: 0755, owner: 'root', group: 'wheel')
  FileUtils.cp("#{release}/etc/login.conf", "#{ramdisk_root}/etc/login.conf")
  system("makefs -b '10%' #{CWD}/cd_root/data/ramdisk.ufs #{ramdisk_root}")
  system("gzip #{CWD}/cd_root/data/ramdisk.ufs")
  FileUtils.rm_rf(ramdisk_root)
end

def boot
  cd_root = "#{CWD}/cd_root"
  FileUtils.cd(release) do
    system("tar -cf - boot | tar -xf - -C #{cd_root}")
  end
  FileUtils.cp('COPYRIGHT', "#{cd_root}/COPYRIGHT")
  FileUtils.cp('LICENSE', "#{cd_root}/LICENSE")
  FileUtils.cp_r('boot/', "#{cd_root}/boot/")
  Dir.mkdir("#{cd_root}/etc")
  system("umount #{release}/dev >/dev/null 2>/dev/null || true")
  system("umount #{release} >/dev/null 2>/dev/null || true")
  system("zpool export ghostbsd")
end

def image
  iso_path = "#{iso}/GhostBSD#{desktop}#{community}.iso"
  FileUtils.cd("script") do
    system("sh mkisoimages.sh -b #{desktop} #{iso_path} #{CWD}/cd_root")
  end
  sha_file = "#{iso}/GhostBSD#{desktop}#{community}.iso.sha256"
  torrent_file = "#{iso}/GhostBSD#{desktop}#{community}.iso.torrent"
  trackers = ["http://tracker.openbittorrent.com:80/announce", 
              "udp://tracker.opentrackr.org:1337", 
              "udp://tracker.coppersurfer.tk:6969"]
  system("sha256 #{iso_path} > #{sha_file}")
  system("transmission-create -o #{torrent_file} -t #{trackers.join(' -t ')} #{iso_path}")
  FileUtils.chmod(0644, torrent_file)
end

# Main Execution
workspace
base
set_ghostbsd_version
if desktop != "test"
  packages_software
  fetch_x_drivers_packages
  rc
  desktop_config
  ghostbsd_config
end
uzip
ramdisk
boot
image
