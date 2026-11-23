//! libdsmshim2 — a *minimal* TWAIN source manager for the Canon DR-S150 driver.
//!
//! Why this exists: the driver notifies its source
//! manager (MSG_XFERREADY, device events) by calling `DSM_Entry()`. It imports that symbol from
//! `/System/Library/Frameworks/TWAIN.framework`, which on recent macOS is a dead stub, so those
//! notifications are lost. The build copies the driver, repoints that one import at this library
//! (`install_name_tool -change`), and we record the notification where the scan engine can see
//! it. Image data still flows through the normal DAT_IMAGEMEMXFER call.
//!
//! Notifications arrive as MSG_INVOKE_CALLBACK (0x0903) with the message as a uint16 at pData+16
//! (0x0101 = XFERREADY, 0x0104 = device event).
//!
//! Everything here is `extern "C"` with the exact layout the ObjC engine (`src/scanjob.m`)
//! `dlsym`s: `shim_ready`, `shim_closereq`, `shim_lastmsg`, `shim_calls` are plain C globals so
//! the engine can poll `shim_ready` without any FFI marshalling.

use std::ffi::c_void;
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::os::raw::{c_int, c_uint};
use std::path::PathBuf;
use std::ptr::{addr_of, addr_of_mut, read_volatile, write_volatile};
use std::sync::{Mutex, OnceLock};

/* ---- state read by the scan engine (src/scanjob.m) ---- */
#[no_mangle]
pub static mut shim_ready: c_int = 0; // set when the driver posts XFERREADY
#[no_mangle]
pub static mut shim_closereq: c_int = 0;
#[no_mangle]
pub static mut shim_lastmsg: c_uint = 0;
#[no_mangle]
pub static mut shim_calls: c_int = 0;

/* ---- TWAIN constants used by the notification channel ---- */
const TWRC_SUCCESS: u16 = 0;
const MSG_GET: u16 = 1;
const MSG_XFERREADY: u16 = 0x0101;
const MSG_CLOSEDSREQ: u16 = 0x0102;
const MSG_CLOSEDSOK: u16 = 0x0103;
const DAT_CALLBACK: u16 = 0x0010;
const DAT_ENTRYPOINT: u16 = 0x0011;
const MSG_INVOKE_CALLBACK: u16 = 0x0903;

/// `TW_ENTRYPOINT` — the vtable the driver asks for so it can call back into us.
#[repr(C)]
pub struct TwEntrypoint {
    pub size: u32,
    pub dsm_entry: *mut c_void,
    pub dsm_mem_allocate: *mut c_void,
    pub dsm_mem_free: *mut c_void,
    pub dsm_mem_lock: *mut c_void,
    pub dsm_mem_unlock: *mut c_void,
}

fn log_path() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    let dir = PathBuf::from(home).join("Library/Logs/DRS150Bridge");
    let _ = fs::create_dir_all(&dir);
    dir.join("shim.log")
}

fn log_file() -> &'static Option<Mutex<File>> {
    static LOG: OnceLock<Option<Mutex<File>>> = OnceLock::new();
    LOG.get_or_init(|| {
        OpenOptions::new()
            .create(true)
            .append(true)
            .open(log_path())
            .ok()
            .map(Mutex::new)
    })
}

fn logline(line: &str) {
    if let Some(file) = log_file() {
        if let Ok(mut f) = file.lock() {
            let _ = writeln!(f, "{line}");
            let _ = f.flush();
        }
    }
}

/* ---- TWAIN memory services, in case the driver asks ---- */
unsafe extern "C" fn mem_allocate(size: u32) -> *mut c_void {
    let p = calloc(1, size as usize);
    logline(&format!("MemAllocate({size}) -> {p:?}"));
    p
}

unsafe extern "C" fn mem_free(ptr: *mut c_void) {
    logline(&format!("MemFree({ptr:?})"));
    free(ptr);
}

unsafe extern "C" fn mem_lock(_ptr: *mut c_void) -> c_int {
    1
}

unsafe extern "C" fn mem_unlock(_ptr: *mut c_void) -> c_int {
    1
}

extern "C" {
    fn calloc(nmemb: usize, size: usize) -> *mut c_void;
    fn free(ptr: *mut c_void);
}

/// The driver's source-manager entry point. Called *by the driver* for notifications, and by
/// us for the entry-point query — signature is the standard TWAIN DSM_Entry ABI.
///
/// # Safety
/// `pdata` is whatever the driver passes; we only read the two bytes it documents at +16.
#[no_mangle]
pub unsafe extern "C" fn DSM_Entry(
    _origin: *mut c_void,
    _dest: *mut c_void,
    dg: u32,
    dat: u16,
    msg: u16,
    pdata: *mut c_void,
) -> u16 {
    write_volatile(
        addr_of_mut!(shim_calls),
        read_volatile(addr_of!(shim_calls)) + 1,
    );

    /* driver -> app notification */
    if dat == DAT_CALLBACK && msg == MSG_INVOKE_CALLBACK && !pdata.is_null() {
        let mut notif: u16 = 0;
        std::ptr::copy_nonoverlapping(
            (pdata as *const u8).add(16),
            &mut notif as *mut u16 as *mut u8,
            2,
        );
        write_volatile(addr_of_mut!(shim_lastmsg), notif as c_uint);
        logline(&format!("INVOKE_CALLBACK notif=0x{notif:04x}"));
        if notif == MSG_XFERREADY {
            write_volatile(addr_of_mut!(shim_ready), 1);
        }
        if notif == MSG_CLOSEDSREQ || notif == MSG_CLOSEDSOK {
            write_volatile(addr_of_mut!(shim_closereq), 1);
        }
        return TWRC_SUCCESS;
    }
    if msg == MSG_XFERREADY {
        write_volatile(addr_of_mut!(shim_lastmsg), MSG_XFERREADY as c_uint);
        write_volatile(addr_of_mut!(shim_ready), 1);
        return TWRC_SUCCESS;
    }

    /* entry point + memory services */
    if dg == 1 /* DG_CONTROL */ && dat == DAT_ENTRYPOINT && msg == MSG_GET && !pdata.is_null() {
        let ep = pdata as *mut TwEntrypoint;
        (*ep).size = std::mem::size_of::<TwEntrypoint>() as u32;
        (*ep).dsm_entry = DSM_Entry as *mut c_void;
        (*ep).dsm_mem_allocate = mem_allocate as *mut c_void;
        (*ep).dsm_mem_free = mem_free as *mut c_void;
        (*ep).dsm_mem_lock = mem_lock as *mut c_void;
        (*ep).dsm_mem_unlock = mem_unlock as *mut c_void;
        logline("ENTRYPOINT served");
        return TWRC_SUCCESS;
    }

    logline(&format!("other DG={dg} DAT=0x{dat:04x} MSG=0x{msg:04x}"));
    TWRC_SUCCESS
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn entrypoint_is_queryable() {
        let mut ep = TwEntrypoint {
            size: 0,
            dsm_entry: std::ptr::null_mut(),
            dsm_mem_allocate: std::ptr::null_mut(),
            dsm_mem_free: std::ptr::null_mut(),
            dsm_mem_lock: std::ptr::null_mut(),
            dsm_mem_unlock: std::ptr::null_mut(),
        };
        let rc = unsafe {
            DSM_Entry(
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                1,
                DAT_ENTRYPOINT,
                MSG_GET,
                &mut ep as *mut TwEntrypoint as *mut c_void,
            )
        };
        assert_eq!(rc, TWRC_SUCCESS);
        assert_eq!(ep.size as usize, std::mem::size_of::<TwEntrypoint>());
        assert!(!ep.dsm_entry.is_null());
    }

    #[test]
    fn xferready_notification_sets_the_flag() {
        unsafe { write_volatile(addr_of_mut!(shim_ready), 0) };
        let mut payload = [0u8; 32];
        payload[16] = 0x01; // XFERREADY, little endian
        payload[17] = 0x01;
        let rc = unsafe {
            DSM_Entry(
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                1,
                DAT_CALLBACK,
                MSG_INVOKE_CALLBACK,
                payload.as_mut_ptr() as *mut c_void,
            )
        };
        assert_eq!(rc, TWRC_SUCCESS);
        assert_eq!(unsafe { read_volatile(addr_of!(shim_ready)) }, 1);
    }
}
