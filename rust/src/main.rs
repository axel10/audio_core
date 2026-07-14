#[cfg(any(target_os = "windows", target_os = "linux"))]
fn main() {
    use rodio::Decoder;
    use rodio_wsola::WsolaSourceExt;
    use std::fs::File;

    // Get an OS sink handle to the default physical sound device.
    // Note that playback stops when the handle is dropped.
    let handle = rodio::DeviceSinkBuilder::open_default_sink().expect("open default audio stream");
    let player = rodio::Player::connect_new(&handle.mixer());
    
    // Load a sound from a file, using a path relative to Cargo.toml.
    let file_path = concat!(env!("CARGO_MANIFEST_DIR"), "/src/test.mp3");
    let file = File::open(file_path).expect("failed to open test.mp3");
    
    // Decode that sound file into a source.
    let source = Decoder::try_from(file).expect("failed to decode test.mp3");
    
    // Wrap it in Wsola at 1.5x speed
    let speed_source = source.wsola(1.5);
    
    // Play the sound directly on the device.
    player.append(speed_source);
    player.sleep_until_end();
}

#[cfg(not(any(target_os = "windows", target_os = "linux")))]
fn main() {
    println!("This binary is only supported on Windows and Linux.");
}

