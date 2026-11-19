//! Android user-space USB Audio (UAC 1.0 / UAC 2.0) exclusive output driver.
//!
//! Architecture & UAC2 protocol handling inspired by Flick (MIT License).
//! Claims USB Audio interfaces via `libusb` (`open_device_with_fd`), detaching
//! the Linux kernel `snd-usb-audio` driver so other apps lose access to the USB
//! DAC while exclusive mode is active.

pub mod descriptor;
pub mod engine;
pub mod iso_scheduler;
pub mod jni_bridge;
