use lofty::config::WriteOptions;
use lofty::picture::{MimeType, Picture, PictureType};
use lofty::prelude::*;
use lofty::probe::Probe;
use lofty::tag::{ItemKey, ItemValue, Tag, TagItem};
use std::path::Path;

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

impl TrackMetadataUpdate {
    fn apply_to_tag(&self, tag: &mut Tag) {
        if let Some(title) = self.title.as_ref().filter(|value| !value.trim().is_empty()) {
            tag.set_title(title.clone());
        }
        if let Some(artist) = self
            .artist
            .as_ref()
            .filter(|value| !value.trim().is_empty())
        {
            tag.set_artist(artist.clone());
        }
        if let Some(album) = self.album.as_ref().filter(|value| !value.trim().is_empty()) {
            tag.set_album(album.clone());
        }
        if let Some(album_artist) = self
            .album_artist
            .as_ref()
            .filter(|value| !value.trim().is_empty())
        {
            tag.insert_text(ItemKey::AlbumArtist, album_artist.clone());
        }
        if let Some(track_number) = self.track_number.and_then(normalize_non_negative_u32) {
            tag.set_track(track_number);
        }
        if let Some(track_total) = self.track_total.and_then(normalize_non_negative_u32) {
            tag.set_track_total(track_total);
        }
        if let Some(disc_number) = self.disc_number.and_then(normalize_non_negative_u32) {
            tag.set_disk(disc_number);
        }

        if let Some(date) = self.date.as_ref().filter(|value| !value.trim().is_empty()) {
            tag.insert_text(ItemKey::RecordingDate, date.clone());
        } else if let Some(year) = self.year {
            tag.insert_text(ItemKey::Year, year.to_string());
        }

        if let Some(comment) = self
            .comment
            .as_ref()
            .filter(|value| !value.trim().is_empty())
        {
            tag.insert_text(ItemKey::Comment, comment.clone());
        }
        if let Some(lyrics) = self
            .lyrics
            .as_ref()
            .filter(|value| !value.trim().is_empty())
        {
            tag.insert_text(ItemKey::UnsyncLyrics, lyrics.clone());
        }
        if let Some(composer) = self
            .composer
            .as_ref()
            .filter(|value| !value.trim().is_empty())
        {
            tag.insert_text(ItemKey::Composer, composer.clone());
        }
        if let Some(lyricist) = self
            .lyricist
            .as_ref()
            .filter(|value| !value.trim().is_empty())
        {
            tag.insert_text(ItemKey::Lyricist, lyricist.clone());
        }
        if let Some(performer) = self
            .performer
            .as_ref()
            .filter(|value| !value.trim().is_empty())
        {
            tag.insert_text(ItemKey::Performer, performer.clone());
        }
        if let Some(conductor) = self
            .conductor
            .as_ref()
            .filter(|value| !value.trim().is_empty())
        {
            tag.insert_text(ItemKey::Conductor, conductor.clone());
        }
        if let Some(remixer) = self
            .remixer
            .as_ref()
            .filter(|value| !value.trim().is_empty())
        {
            tag.insert_text(ItemKey::Remixer, remixer.clone());
        }

        if !self.genres.is_empty() {
            tag.remove_key(ItemKey::Genre);
            for genre in self.genres.iter().filter(|value| !value.trim().is_empty()) {
                tag.push(TagItem::new(ItemKey::Genre, ItemValue::Text(genre.clone())));
            }
        }

        if !self.pictures.is_empty() {
            for picture in &self.pictures {
                if let Some(pic_type) = parse_picture_type(&picture.picture_type) {
                    tag.remove_picture_type(pic_type);
                    tag.push_picture(
                        Picture::unchecked(picture.bytes.clone())
                            .mime_type(parse_mime_type(&picture.mime_type))
                            .pic_type(pic_type)
                            .description_if_present(picture.description.clone())
                            .build(),
                    );
                }
            }
        }
    }
}

pub fn update_track_metadata(path: String, metadata: TrackMetadataUpdate) -> anyhow::Result<()> {
    let path = Path::new(&path);
    let mut tagged_file = Probe::open(path)?.read()?;
    let tag = ensure_editable_tag(&mut tagged_file);

    metadata.apply_to_tag(tag);
    tagged_file.save_to_path(path, WriteOptions::default())?;

    Ok(())
}

fn ensure_editable_tag(tagged_file: &mut lofty::file::TaggedFile) -> &mut Tag {
    let tag_type = tagged_file.primary_tag_type();

    if tagged_file.tag(tag_type).is_some() {
        return tagged_file
            .tag_mut(tag_type)
            .expect("primary tag should exist");
    }

    if tagged_file.first_tag().is_some() {
        return tagged_file.first_tag_mut().expect("first tag should exist");
    }

    tagged_file.insert_tag(Tag::new(tag_type));
    tagged_file
        .tag_mut(tag_type)
        .expect("primary tag should exist after insertion")
}

fn normalize_non_negative_u32(value: i32) -> Option<u32> {
    u32::try_from(value).ok()
}

fn parse_mime_type(mime_type: &str) -> MimeType {
    MimeType::from_str(mime_type)
}

fn parse_picture_type(label: &str) -> Option<PictureType> {
    let normalized = label.trim().to_lowercase();
    let picture_type = match normalized.as_str() {
        "front cover" | "cover front" | "cover art (front)" | "front" => PictureType::CoverFront,
        "back cover" | "cover back" | "cover art (back)" | "back" => PictureType::CoverBack,
        "leaflet page" | "leaflet" | "cover art (leaflet)" => PictureType::Leaflet,
        "media label cd" | "media label" | "cover art (media)" => PictureType::Media,
        "artist / performer" | "lead artist" | "artist" | "cover art (lead artist)" => {
            PictureType::LeadArtist
        }
        "band logo" | "band logotype" | "cover art (band logotype)" => PictureType::BandLogo,
        "other icon" | "cover art (icon)" => PictureType::OtherIcon,
        "icon" | "png icon" | "cover art (png icon)" => PictureType::Icon,
        "conductor" | "cover art (conductor)" => PictureType::Conductor,
        "composer" | "cover art (composer)" => PictureType::Composer,
        "lyricist" | "cover art (lyricist)" => PictureType::Lyricist,
        "during recording" => PictureType::DuringRecording,
        "during performance" => PictureType::DuringPerformance,
        "screen capture" | "screenshot" => PictureType::ScreenCapture,
        "fish" => PictureType::BrightFish,
        "illustration" => PictureType::Illustration,
        "publisher logo" | "cover art (publisher logotype)" => PictureType::PublisherLogo,
        "other" | "cover art (other)" | "" => PictureType::Other,
        _ => PictureType::Other,
    };

    Some(picture_type)
}

trait PictureBuilderExt {
    fn description_if_present(self, description: Option<String>) -> Self;
}

impl PictureBuilderExt for lofty::picture::PictureBuilder {
    fn description_if_present(self, description: Option<String>) -> Self {
        if let Some(description) = description.filter(|value| !value.trim().is_empty()) {
            self.description(description)
        } else {
            self
        }
    }
}
