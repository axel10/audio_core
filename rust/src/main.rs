#[cfg(not(target_os = "android"))]
fn main() {
    use rodio::Decoder;
    use std::fs::File;
    use std::time::Duration;

    // Get an OS sink handle to the default physical sound device.
    // Note that playback stops when the handle is dropped.
    let handle = rodio::DeviceSinkBuilder::open_default_sink().expect("open default audio stream");
    let player = rodio::Player::connect_new(&handle.mixer());
    // Load a sound from a file, using a path relative to Cargo.toml.
    let file =
        File::open(r#"E:\vc_space\lib\35.V Union -Joke-\Disc 1\06 おこちゃま戦争.m4a"#).unwrap();
    // Decode that sound file into a source.
    let source = Decoder::try_from(file).unwrap();
    // Play the sound directly on the device.
    player.append(source);
    let _ = player.try_seek(Duration::from_secs(150));
    player.sleep_until_end();
}

#[cfg(target_os = "android")]
fn main() {}
