use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let input_dir = std::env::args_os()
        .nth(1)
        .map(PathBuf::from)
        .unwrap_or_else(default_input_dir);

    let mut snapshots = BTreeMap::<String, BTreeMap<String, u32>>::new();
    for raw_file in sorted_raw_files(&input_dir)? {
        let bytes = fs::read(&raw_file)?;
        let file_name = raw_file
            .file_name()
            .and_then(|value| value.to_str())
            .ok_or("invalid UTF-8 file name")?;

        let theme_colors =
            palette_core::debug_build_theme_colors_from_pixels(&bytes, infer_channels(&raw_file))
                .unwrap_or_default();
        snapshots.insert(file_name.to_string(), theme_colors);
    }

    println!("{}", serde_json::to_string(&snapshots)?);
    Ok(())
}

fn default_input_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|path| path.parent())
        .expect("crate should live under repo root")
        .join("test")
        .join("decoed_imgs")
}

fn infer_channels(path: &Path) -> usize {
    match path
        .extension()
        .and_then(|value| value.to_str())
        .map(|value| value.to_ascii_lowercase())
        .as_deref()
    {
        Some("rgba") => 4,
        _ => 3,
    }
}

fn sorted_raw_files(dir: &Path) -> Result<Vec<PathBuf>, Box<dyn std::error::Error>> {
    let mut entries = fs::read_dir(dir)?
        .map(|entry| entry.map(|item| item.path()))
        .collect::<Result<Vec<_>, _>>()?;
    entries.retain(|path| {
        path.extension()
            .and_then(|value| value.to_str())
            .is_some_and(|value| {
                value.eq_ignore_ascii_case("raw") || value.eq_ignore_ascii_case("rgba")
            })
    });
    entries.sort();
    Ok(entries)
}
