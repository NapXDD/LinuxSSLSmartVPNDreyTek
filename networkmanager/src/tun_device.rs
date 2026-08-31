/// TUN device creation for the NM plugin.
///
/// Running as root (spawned by NM), so we can create the TUN device directly
/// without pkexec or capability checks.
use anyhow::{Context, Result};
use std::ffi::CString;
use std::net::Ipv4Addr;
use std::os::unix::io::RawFd;
use tracing::info;

// ioctl request code for TUNSETIFF
const TUNSETIFF: libc::c_ulong = 0x400454ca;

/// Create a TUN device, configure its IP and MTU, and bring it up.
///
/// The device is created by TUNSETIFF itself rather than pre-created with
/// `ip tuntap add`: on Fedora with SELinux enforcing, a device pre-created by
/// `ip` carries ifconfig_t's tun_socket label, and NetworkManager_t (our
/// domain) is not allowed to relabelfrom it — attaching then fails with
/// EACCES. Creating the device in our own domain only needs
/// self:tun_socket create, which the stock policy grants.
///
/// The resulting device is non-persistent: the kernel removes it when the
/// returned fd closes, so error and teardown cleanup are automatic.
pub fn create_tun(
    name: &str,
    local_ip: Ipv4Addr,
    peer_ip: Ipv4Addr,
    mtu: u16,
) -> Result<tun_rs::AsyncDevice> {
    info!("Creating TUN device {name}");

    let c_name = CString::new(name).context("Invalid TUN device name")?;

    let fd = unsafe { libc::open(c"/dev/net/tun".as_ptr(), libc::O_RDWR | libc::O_CLOEXEC) };
    if fd < 0 {
        return Err(std::io::Error::last_os_error()).context("Failed to open /dev/net/tun");
    }

    if let Err(e) = attach_tun(fd, &c_name) {
        unsafe {
            libc::close(fd);
        }
        return Err(e);
    }

    // From here dropping `device` closes the fd, which also removes the
    // interface — configuration failures below clean up implicitly.
    let device = unsafe { tun_rs::AsyncDevice::from_fd(fd) }
        .context("Failed to create AsyncDevice from TUN fd")?;

    run_ip(&[
        "addr",
        "add",
        &format!("{local_ip}"),
        "peer",
        &format!("{peer_ip}"),
        "dev",
        name,
    ])?;
    run_ip(&["link", "set", name, "mtu", &mtu.to_string(), "up"])?;

    info!("TUN device {name} created and configured");
    Ok(device)
}

/// Run an `ip` subcommand, failing on non-zero exit.
fn run_ip(args: &[&str]) -> Result<()> {
    let status = std::process::Command::new("ip")
        .args(args)
        .status()
        .with_context(|| format!("Failed to run ip {}", args.join(" ")))?;
    if !status.success() {
        anyhow::bail!("ip {} failed with {status}", args.join(" "));
    }
    Ok(())
}

/// Create-and-attach a TUN device via TUNSETIFF ioctl.
fn attach_tun(fd: RawFd, name: &CString) -> Result<()> {
    unsafe {
        let mut req: libc::ifreq = std::mem::zeroed();

        std::ptr::copy_nonoverlapping(
            name.as_ptr() as *const libc::c_char,
            req.ifr_name.as_mut_ptr(),
            name.as_bytes_with_nul().len(),
        );

        req.ifr_ifru.ifru_flags = (libc::IFF_TUN | libc::IFF_NO_PI) as libc::c_short;

        let ret = libc::ioctl(fd, TUNSETIFF as _, &mut req as *mut _);
        if ret < 0 {
            return Err(std::io::Error::last_os_error()).context("TUNSETIFF ioctl failed");
        }
    }
    Ok(())
}
