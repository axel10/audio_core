use std::path::Path;

use lofty::config::WriteOptions;
use lofty::prelude::*;
use lofty::probe::Probe;
use lofty::tag::{ItemKey, Tag, TagType};

use id3::frame::{
    Comment as Id3Comment, ExtendedText as Id3ExtendedText, Lyrics as Id3Lyrics,
    Picture as Id3Picture, PictureType as Id3PictureType,
};
use id3::{Tag as Id3Tag, TagLike as _, Version as Id3Version};

#[derive(Debug, Clone, Default)]
pub struct TrackPicture {
    pub bytes: Vec<u8>,
    pub mime_type: String,
    pub picture_type: String,
    pub description: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct TrackMetadataUpdate {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub track_number: Option<i32>,
    pub track_total: Option<i32>,
    pub disc_number: Option<i32>,
    pub date: Option<String>,
    pub year: Option<i32>,
    pub comment: Option<String>,
    pub lyrics: Option<String>,
    pub composer: Option<String>,
    pub lyricist: Option<String>,
    pub performer: Option<String>,
    pub conductor: Option<String>,
    pub remixer: Option<String>,
    pub genres: Vec<String>,
    pub pictures: Vec<TrackPicture>,
}

pub fn update_track_metadata(path: String, metadata: TrackMetadataUpdate) -> anyhow::Result<()> {
    if should_use_id3(&path) {
        return update_track_metadata_with_id3(path, metadata);
    }

    update_track_metadata_with_lofty(path, metadata)
}

pub fn get_track_metadata(path: String) -> TrackMetadataUpdate {
    if should_use_id3(&path) {
        return read_track_metadata_with_id3(&path);
    }

    read_track_metadata_with_lofty(&path)
}

fn should_use_id3(path: &str) -> bool {
    matches!(
        Path::new(path)
            .extension()
            .and_then(|ext| ext.to_str())
            .map(|ext| ext.to_ascii_lowercase())
            .as_deref(),
        Some("mp3" | "wav" | "aiff" | "aif")
    )
}

fn update_track_metadata_with_id3(
    path: String,
    metadata: TrackMetadataUpdate,
) -> anyhow::Result<()> {
    let mut tag = Id3Tag::read_from_path(&path).unwrap_or_else(|_| Id3Tag::new());

    if let Some(v) = metadata.title {
        tag.set_title(v);
    }
    if let Some(v) = metadata.artist {
        tag.set_artist(v);
    }
    if let Some(v) = metadata.album {
        tag.set_album(v);
    }
    if let Some(v) = metadata.album_artist {
        tag.set_album_artist(v);
    }
    if let Some(v) = metadata.track_number {
        tag.set_track(v as u32);
    }
    if let Some(v) = metadata.track_total {
        tag.set_total_tracks(v as u32);
    }
    if let Some(v) = metadata.disc_number {
        tag.set_disc(v as u32);
    }
    if let Some(v) = metadata.date {
        tag.set_text("TDRC", v);
    } else if let Some(v) = metadata.year {
        tag.set_year(v);
    }

    if let Some(v) = metadata.comment {
        tag.add_frame(Id3Comment {
            lang: "eng".to_string(),
            description: String::new(),
            text: v,
        });
    }

    if let Some(v) = metadata.lyrics {
        tag.add_frame(Id3Lyrics {
            lang: "eng".to_string(),
            description: String::new(),
            text: v,
        });
    }

    if let Some(v) = metadata.composer {
        tag.set_text("TCOM", v);
    }
    if let Some(v) = metadata.lyricist {
        tag.set_text("TEXT", v);
    }
    if let Some(v) = metadata.performer {
        tag.set_text("TPE3", v);
    }
    if let Some(v) = metadata.conductor {
        tag.add_frame(Id3ExtendedText {
            description: "CONDUCTOR".to_string(),
            value: v,
        });
    }
    if let Some(v) = metadata.remixer {
        tag.add_frame(Id3ExtendedText {
            description: "REMIXER".to_string(),
            value: v,
        });
    }

    if let Some(v) = metadata.genres.first() {
        tag.set_genre(v.clone());
    }

    for pic in metadata.pictures {
        let pic_type = match pic.picture_type.to_lowercase().as_str() {
            "front" | "cover front" | "front cover" => Id3PictureType::CoverFront,
            "back" | "cover back" | "back cover" => Id3PictureType::CoverBack,
            _ => Id3PictureType::Other,
        };

        tag.add_frame(Id3Picture {
            mime_type: pic.mime_type,
            picture_type: pic_type,
            description: pic.description.unwrap_or_default(),
            data: pic.bytes,
        });
    }

    tag.write_to_path(&path, Id3Version::Id3v24)?;
    Ok(())
}

fn update_track_metadata_with_lofty(
    path: String,
    metadata: TrackMetadataUpdate,
) -> anyhow::Result<()> {
    // 1. 读取音频文件 (简洁版本，参考 demo)
    let mut tagged_file = Probe::open(&path)?.read()?;

    // 2. 获取可变的 Tag (优先主标签，其次第一个标签，都没有则新建)
    let tag = match tagged_file.primary_tag_mut() {
        Some(primary) => primary,
        None => match tagged_file.first_tag_mut() {
            Some(first) => first,
            None => {
                let tag_type = tagged_file.primary_tag_type();
                tagged_file.insert_tag(Tag::new(tag_type));
                tagged_file.primary_tag_mut().unwrap()
            }
        },
    };

    // 如果歌曲是 ID3v1，则将其转换为 ID3v2，旧的 v1 标签保留在原处
    if tag.tag_type() == TagType::Id3v1 {
        println!("ID3v1 detected, upgrading to ID3v2...");
        // 将内存中的标签对象转换为 ID3v2，以便支持封面等现代特性
        tag.re_map(TagType::Id3v2);
    }

    // 3. 设置标签内容 (全部交给 lofty Accessor 和 ItemKey 处理)
    if let Some(v) = metadata.title {
        tag.set_title(v);
    }
    if let Some(v) = metadata.artist {
        tag.set_artist(v);
    }
    if let Some(v) = metadata.album {
        tag.set_album(v);
    }
    if let Some(v) = metadata.genres.get(0) {
        tag.set_genre(v.clone());
    }
    if let Some(v) = metadata.track_number {
        tag.set_track(v as u32);
    }
    if let Some(v) = metadata.track_total {
        tag.set_track_total(v as u32);
    }
    if let Some(v) = metadata.disc_number {
        tag.set_disk(v as u32);
    }
    if let Some(v) = metadata.date {
        tag.insert_text(ItemKey::RecordingDate, v);
    } else if let Some(v) = metadata.year {
        tag.insert_text(ItemKey::Year, v.to_string());
    }

    // 其他通用项
    if let Some(v) = metadata.album_artist {
        tag.insert_text(ItemKey::AlbumArtist, v);
    }
    if let Some(v) = metadata.comment {
        tag.insert_text(ItemKey::Comment, v);
    }
    if let Some(v) = metadata.lyrics {
        tag.insert_text(ItemKey::UnsyncLyrics, v);
    }
    if let Some(v) = metadata.composer {
        tag.insert_text(ItemKey::Composer, v);
    }
    if let Some(v) = metadata.lyricist {
        tag.insert_text(ItemKey::Lyricist, v);
    }
    if let Some(v) = metadata.performer {
        tag.insert_text(ItemKey::Performer, v);
    }
    if let Some(v) = metadata.conductor {
        tag.insert_text(ItemKey::Conductor, v);
    }
    if let Some(v) = metadata.remixer {
        tag.insert_text(ItemKey::Remixer, v);
    }

    // 图片处理
    if !metadata.pictures.is_empty() {
        use lofty::picture::{MimeType, Picture, PictureType};
        for pic in metadata.pictures {
            let pic_type = match pic.picture_type.to_lowercase().as_str() {
                "front" | "cover front" | "front cover" => PictureType::CoverFront,
                "back" | "cover back" | "back cover" => PictureType::CoverBack,
                _ => PictureType::Other,
            };
            tag.remove_picture_type(pic_type);
            tag.push_picture(
                Picture::unchecked(pic.bytes)
                    .mime_type(MimeType::from_str(&pic.mime_type))
                    .pic_type(pic_type)
                    .build(),
            );
        }
    }

    // 4. 保存标签 (默认根据文件类型选择最佳方案)
    tag.save_to_path(&path, WriteOptions::default())?;

    Ok(())
}

fn read_track_metadata_with_id3(path: &str) -> TrackMetadataUpdate {
    let Ok(tag) = Id3Tag::read_from_path(path) else {
        return TrackMetadataUpdate::default();
    };

    let title = tag.title().map(|v| v.to_string());
    let artist = tag.artist().map(|v| v.to_string());
    let album = tag.album().map(|v| v.to_string());
    let album_artist = tag.album_artist().map(|v| v.to_string());
    let track_number = tag.track().map(|v| v as i32);
    let track_total = tag.total_tracks().map(|v| v as i32);
    let disc_number = tag.disc().map(|v| v as i32);
    let date = tag.date_recorded().map(|v| v.to_string());
    let year = tag.year();
    let comment = tag.comments().next().map(|comment| comment.text.clone());
    let lyrics = tag.lyrics().next().map(|lyrics| lyrics.text.clone());
    let composer = first_text_frame_value(&tag, "TCOM");
    let lyricist = first_text_frame_value(&tag, "TEXT");
    let performer = first_text_frame_value(&tag, "TPE3");
    let conductor = first_extended_text_value(&tag, "CONDUCTOR");
    let remixer = first_extended_text_value(&tag, "REMIXER");
    let genres = tag
        .genres_parsed()
        .into_iter()
        .map(|genre| genre.into_owned())
        .collect::<Vec<_>>();
    let pictures = tag
        .pictures()
        .map(|picture| TrackPicture {
            bytes: picture.data.clone(),
            mime_type: picture.mime_type.clone(),
            picture_type: id3_picture_type_to_label(picture.picture_type),
            description: if picture.description.is_empty() {
                None
            } else {
                Some(picture.description.clone())
            },
        })
        .collect::<Vec<_>>();

    TrackMetadataUpdate {
        title,
        artist,
        album,
        album_artist,
        track_number,
        track_total,
        disc_number,
        date,
        year,
        comment,
        lyrics,
        composer,
        lyricist,
        performer,
        conductor,
        remixer,
        genres,
        pictures,
    }
}

fn read_track_metadata_with_lofty(path: &str) -> TrackMetadataUpdate {
    let Ok(tagged_file) = Probe::open(path).and_then(|probe| probe.read()) else {
        return TrackMetadataUpdate::default();
    };

    let Some(tag) = tagged_file.primary_tag().or_else(|| tagged_file.first_tag()) else {
        return TrackMetadataUpdate::default();
    };

    let title = tag.title().map(|v| v.to_string());
    let artist = tag.artist().map(|v| v.to_string());
    let album = tag.album().map(|v| v.to_string());
    let album_artist = first_tag_value(tag, ItemKey::AlbumArtist);
    let track_number = tag.track().map(|v| v as i32);
    let track_total = tag.track_total().map(|v| v as i32);
    let disc_number = tag.disk().map(|v| v as i32);
    let date = tag.date().map(|v| v.to_string());
    let year = tag.date().map(|v| i32::from(v.year));
    let comment = tag.comment().map(|v| v.to_string()).or_else(|| {
        first_tag_value(tag, ItemKey::Comment)
    });
    let lyrics = first_tag_value(tag, ItemKey::UnsyncLyrics)
        .or_else(|| first_tag_value(tag, ItemKey::Lyrics));
    let composer = first_tag_value(tag, ItemKey::Composer);
    let lyricist = first_tag_value(tag, ItemKey::Lyricist);
    let performer = first_tag_value(tag, ItemKey::Performer);
    let conductor = first_tag_value(tag, ItemKey::Conductor);
    let remixer = first_tag_value(tag, ItemKey::Remixer);
    let genres = tag
        .get_strings(ItemKey::Genre)
        .map(str::to_string)
        .collect::<Vec<_>>();
    let pictures = tag
        .pictures()
        .iter()
        .map(|picture| TrackPicture {
            bytes: picture.data().to_vec(),
            mime_type: picture
                .mime_type()
                .map(|mime| mime.to_string())
                .unwrap_or_else(|| "image/jpeg".to_string()),
            picture_type: lofty_picture_type_to_label(picture.pic_type()),
            description: picture.description().map(str::to_string),
        })
        .collect::<Vec<_>>();

    TrackMetadataUpdate {
        title,
        artist,
        album,
        album_artist,
        track_number,
        track_total,
        disc_number,
        date,
        year,
        comment,
        lyrics,
        composer,
        lyricist,
        performer,
        conductor,
        remixer,
        genres,
        pictures,
    }
}

fn first_tag_value(tag: &Tag, key: ItemKey) -> Option<String> {
    tag.get_strings(key).next().map(str::to_string)
}

fn first_text_frame_value(tag: &Id3Tag, frame_id: &str) -> Option<String> {
    tag.get(frame_id)
        .and_then(|frame| frame.content().text())
        .map(str::to_string)
}

fn first_extended_text_value(tag: &Id3Tag, description: &str) -> Option<String> {
    tag.frames().find_map(|frame| {
        let ext = frame.content().extended_text()?;
        if ext.description.eq_ignore_ascii_case(description) {
            Some(ext.value.clone())
        } else {
            None
        }
    })
}

fn id3_picture_type_to_label(picture_type: Id3PictureType) -> String {
    match picture_type {
        Id3PictureType::CoverFront => "Front Cover".to_string(),
        Id3PictureType::CoverBack => "Back Cover".to_string(),
        Id3PictureType::Leaflet => "Leaflet Page".to_string(),
        Id3PictureType::Media => "Media Label CD".to_string(),
        Id3PictureType::LeadArtist => "Lead Artist".to_string(),
        Id3PictureType::Artist => "Artist / Performer".to_string(),
        Id3PictureType::Conductor => "Conductor".to_string(),
        Id3PictureType::Band => "Band Logo".to_string(),
        Id3PictureType::BandLogo => "Band Logo".to_string(),
        Id3PictureType::Composer => "Composer".to_string(),
        Id3PictureType::Lyricist => "Lyricist".to_string(),
        Id3PictureType::RecordingLocation => "Recording Location".to_string(),
        Id3PictureType::DuringRecording => "During Recording".to_string(),
        Id3PictureType::DuringPerformance => "During Performance".to_string(),
        Id3PictureType::ScreenCapture => "Screen Capture".to_string(),
        Id3PictureType::BrightFish => "Bright Fish".to_string(),
        Id3PictureType::Illustration => "Illustration".to_string(),
        Id3PictureType::PublisherLogo => "Publisher Logo".to_string(),
        Id3PictureType::Other => "Other".to_string(),
        Id3PictureType::OtherIcon => "Other Icon".to_string(),
        Id3PictureType::Icon => "Icon".to_string(),
        Id3PictureType::Undefined(v) => format!("Undefined({v})"),
    }
}

fn lofty_picture_type_to_label(picture_type: lofty::picture::PictureType) -> String {
    match picture_type {
        lofty::picture::PictureType::CoverFront => "Front Cover".to_string(),
        lofty::picture::PictureType::CoverBack => "Back Cover".to_string(),
        lofty::picture::PictureType::Leaflet => "Leaflet Page".to_string(),
        lofty::picture::PictureType::Media => "Media Label CD".to_string(),
        lofty::picture::PictureType::LeadArtist => "Lead Artist".to_string(),
        lofty::picture::PictureType::Artist => "Artist / Performer".to_string(),
        lofty::picture::PictureType::Conductor => "Conductor".to_string(),
        lofty::picture::PictureType::Band => "Band Logo".to_string(),
        lofty::picture::PictureType::Composer => "Composer".to_string(),
        lofty::picture::PictureType::Lyricist => "Lyricist".to_string(),
        lofty::picture::PictureType::RecordingLocation => "Recording Location".to_string(),
        lofty::picture::PictureType::DuringRecording => "During Recording".to_string(),
        lofty::picture::PictureType::DuringPerformance => "During Performance".to_string(),
        lofty::picture::PictureType::ScreenCapture => "Screen Capture".to_string(),
        lofty::picture::PictureType::BrightFish => "Bright Fish".to_string(),
        lofty::picture::PictureType::Illustration => "Illustration".to_string(),
        lofty::picture::PictureType::PublisherLogo => "Publisher Logo".to_string(),
        lofty::picture::PictureType::Other => "Other".to_string(),
        lofty::picture::PictureType::Icon => "Icon".to_string(),
        lofty::picture::PictureType::OtherIcon => "Other Icon".to_string(),
        lofty::picture::PictureType::Undefined(v) => format!("Undefined({v})"),
        _ => "Other".to_string(),
    }
}

pub fn remove_all_tags(path: String) -> anyhow::Result<()> {
    if should_use_id3(&path) {
        id3::v1v2::remove_from_path(&path)?;
        return Ok(());
    }

    let tagged_file = Probe::open(&path)?.read()?;
    for tag in tagged_file.tags() {
        tag.tag_type().remove_from_path(&path)?;
    }
    Ok(())
}
