use pgrx::prelude::*;
use serde::Serialize;

/// ActivityPub Actor types per ActivityStreams vocabulary.
#[derive(PostgresEnum, Serialize, Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApActorType {
    Person,
    Group,
    Application,
    Service,
    Organization,
}

/// ActivityPub Activity types — the verbs of federation.
#[derive(PostgresEnum, Serialize, Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApActivityType {
    Create,
    Update,
    Delete,
    Follow,
    Accept,
    Reject,
    Like,
    Announce,
    Undo,
    Block,
    Flag,
    Move,
    Add,
    Remove,
}

/// ActivityPub Object types — the nouns of content.
#[derive(PostgresEnum, Serialize, Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApObjectType {
    Note,
    Article,
    Image,
    Video,
    Audio,
    Page,
    Event,
    Question,
    Document,
}

/// Visibility model (de facto Mastodon standard, not in the W3C spec).
#[derive(PostgresEnum, Serialize, Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApVisibility {
    Public,
    Unlisted,
    FollowersOnly,
    Direct,
}

/// Outbound delivery queue status.
#[derive(PostgresEnum, Serialize, Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApDeliveryStatus {
    Queued,
    Delivered,
    Failed,
    Expired,
}
