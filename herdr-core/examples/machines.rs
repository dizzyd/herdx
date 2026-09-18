//! Exercises the machine catalog against a throwaway state directory.

use herdr_core::ffi::*;

fn text(ptr: *mut std::ffi::c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    unsafe {
        let value = std::ffi::CStr::from_ptr(ptr).to_string_lossy().into_owned();
        hx_string_free(ptr);
        value
    }
}

fn c(value: &str) -> std::ffi::CString {
    std::ffi::CString::new(value).unwrap()
}

fn main() {
    unsafe {
        println!("start: {}", text(hx_machines_json()));

        let id = text(hx_machine_save(
            std::ptr::null(),
            c("Test Box").as_ptr(),
            c("test.example").as_ptr(),
            c("default").as_ptr(),
            true,
        ));
        println!("added: {id}");
        println!("after add: {}", text(hx_machines_json()));

        let renamed = text(hx_machine_save(
            c(&id).as_ptr(),
            c("Renamed").as_ptr(),
            c("test.example").as_ptr(),
            c("").as_ptr(),
            false,
        ));
        println!("edited: {renamed}");
        println!("after edit: {}", text(hx_machines_json()));

        // Rejections the catalog's own rules require.
        for (label, target) in [("", "host"), ("ok", "user:secret@host")] {
            let failed = hx_machine_save(
                std::ptr::null(),
                c(label).as_ptr(),
                c(target).as_ptr(),
                c("default").as_ptr(),
                true,
            );
            println!("reject {label:?}/{target:?}: {}", text(hx_machine_error()));
            assert!(failed.is_null());
        }

        println!("removed: {}", hx_machine_remove(c(&id).as_ptr()));
        println!("end: {}", text(hx_machines_json()));
    }
}
