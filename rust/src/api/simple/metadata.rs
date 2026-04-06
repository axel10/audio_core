use lofty::config::WriteOptions;
use lofty::prelude::*;
use lofty::probe::Probe;
use lofty::tag::{ItemKey, Tag, TagType};

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
    if let Some(v) = metadata.title { tag.set_title(v); }
    if let Some(v) = metadata.artist { tag.set_artist(v); }
    if let Some(v) = metadata.album { tag.set_album(v); }
    if let Some(v) = metadata.genres.get(0) { tag.set_genre(v.clone()); }
    if let Some(v) = metadata.track_number { tag.set_track(v as u32); }
    if let Some(v) = metadata.track_total { tag.set_track_total(v as u32); }
    if let Some(v) = metadata.disc_number { tag.set_disk(v as u32); }
    if let Some(v) = metadata.date { tag.insert_text(ItemKey::RecordingDate, v); }
    else if let Some(v) = metadata.year { tag.insert_text(ItemKey::Year, v.to_string()); }

    // 其他通用项
    if let Some(v) = metadata.album_artist { tag.insert_text(ItemKey::AlbumArtist, v); }
    if let Some(v) = metadata.comment { tag.insert_text(ItemKey::Comment, v); }
    if let Some(v) = metadata.lyrics { tag.insert_text(ItemKey::UnsyncLyrics, v); }
    if let Some(v) = metadata.composer { tag.insert_text(ItemKey::Composer, v); }
    if let Some(v) = metadata.lyricist { tag.insert_text(ItemKey::Lyricist, v); }
    if let Some(v) = metadata.performer { tag.insert_text(ItemKey::Performer, v); }
    if let Some(v) = metadata.conductor { tag.insert_text(ItemKey::Conductor, v); }
    if let Some(v) = metadata.remixer { tag.insert_text(ItemKey::Remixer, v); }

    // 图片处理
    if !metadata.pictures.is_empty() {
        use lofty::picture::{Picture, PictureType, MimeType};
        for pic in metadata.pictures {
            let pic_type = match pic.picture_type.to_lowercase().as_str() {
                "front" | "cover front" | "front cover" => PictureType::CoverFront,
                "back" | "cover back" | "back cover" => PictureType::CoverBack,
                _ => PictureType::Other,
            };
            tag.remove_picture_type(pic_type);
            tag.push_picture(Picture::unchecked(pic.bytes)
                .mime_type(MimeType::from_str(&pic.mime_type))
                .pic_type(pic_type)
                .build());
        }
    }

    // 4. 保存标签 (默认根据文件类型选择最佳方案)
    tag.save_to_path(&path, WriteOptions::default())?;

    Ok(())
}

pub fn remove_all_tags(path: String) -> anyhow::Result<()> {
    let tagged_file = Probe::open(&path)?.read()?;
    for tag in tagged_file.tags() {
        tag.tag_type().remove_from_path(&path)?;
    }
    Ok(())
}
