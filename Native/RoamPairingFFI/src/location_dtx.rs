//! Keep idevice's DTX framing, handshake and channel router. Its public `call_method`
//! does not return the generated identifier, so observe the outgoing dispatch
//! header on the LocationSimulation transport and correlate the typed reply.
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use std::{io, time::Duration};

use idevice::dvt::errors::DvtError;
use idevice::dvt::message::{AuxValue, Message};
use idevice::dvt::remote_server::{Channel, RemoteServerClient};
use idevice::{IdeviceError, ReadWrite, RsdService};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::time::timeout;

const HEADER_LEN: usize = 32;
const DTX_OK: u8 = 0;
const DTX_OBJECT: u8 = 3;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Request {
    identifier: u32,
    channel: i32,
}

#[derive(Debug, Default)]
struct OutgoingHeaders {
    header: [u8; HEADER_LEN],
    buffered: usize,
    remaining: usize,
    location_request: Option<Request>,
}

impl OutgoingHeaders {
    fn observe(&mut self, mut bytes: &[u8]) {
        while !bytes.is_empty() {
            if self.remaining > 0 {
                let skip = self.remaining.min(bytes.len());
                self.remaining -= skip;
                bytes = &bytes[skip..];
                continue;
            }
            let buffered = (HEADER_LEN - self.buffered).min(bytes.len());
            self.header[self.buffered..self.buffered + buffered]
                .copy_from_slice(&bytes[..buffered]);
            self.buffered += buffered;
            bytes = &bytes[buffered..];
            if self.buffered == HEADER_LEN {
                self.buffered = 0;
                let fragment_id = u16::from_le_bytes(self.header[8..10].try_into().unwrap());
                let fragment_count = u16::from_le_bytes(self.header[10..12].try_into().unwrap());
                // idevice currently writes unfragmented calls. Its DTX framing
                // defines the first header of a fragmented message as header-only.
                let starts_fragmented = fragment_id == 0 && fragment_count > 1;
                self.remaining = if starts_fragmented {
                    0
                } else {
                    u32_at(&self.header, 12) as usize
                };
                let channel = u32_at(&self.header, 24) as i32;
                // Only the single borrowed non-root channel can send a command
                // expecting a reply. Control-channel traffic and ACKs do not count.
                if fragment_id == 0
                    && channel > 0
                    && u32_at(&self.header, 20) == 0
                    && u32_at(&self.header, 28) == 1
                {
                    self.location_request = Some(Request {
                        identifier: u32_at(&self.header, 16),
                        channel,
                    });
                }
            }
        }
    }
}

fn u32_at(bytes: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap())
}

#[derive(Clone, Debug, Default)]
pub struct LocationRequests(Arc<Mutex<OutgoingHeaders>>);

impl LocationRequests {
    fn latest(&self) -> Option<Request> {
        self.0.lock().unwrap().location_request
    }
}

#[derive(Debug)]
struct ObservedTransport<R> {
    stream: R,
    requests: LocationRequests,
}

impl<R: AsyncRead + Unpin> AsyncRead for ObservedTransport<R> {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().stream).poll_read(cx, buf)
    }
}

impl<R: AsyncWrite + Unpin> AsyncWrite for ObservedTransport<R> {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        let this = self.get_mut();
        let result = Pin::new(&mut this.stream).poll_write(cx, buf);
        if let Poll::Ready(Ok(len)) = result {
            this.requests.0.lock().unwrap().observe(&buf[..len]);
        }
        result
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().stream).poll_flush(cx)
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().stream).poll_shutdown(cx)
    }
}

pub struct LocationDtx {
    pub server: RemoteServerClient<Box<dyn ReadWrite>>,
    pub requests: LocationRequests,
}

impl LocationDtx {
    fn new(stream: impl ReadWrite + 'static) -> Self {
        let requests = LocationRequests::default();
        let server = RemoteServerClient::new(ObservedTransport {
            stream,
            requests: requests.clone(),
        });
        Self { server, requests }
    }
}

impl RsdService for LocationDtx {
    fn rsd_service_name() -> std::borrow::Cow<'static, str> {
        RemoteServerClient::rsd_service_name()
    }

    async fn from_stream(stream: Box<dyn ReadWrite>) -> Result<Self, IdeviceError> {
        Ok(Self::new(stream))
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum CommandError {
    Disconnected,
    Timeout,
    Rejected,
}

fn transport_error(error: IdeviceError) -> CommandError {
    match error {
        IdeviceError::Socket(_) | IdeviceError::SessionInactive => CommandError::Disconnected,
        IdeviceError::Dvt(DvtError::UnknownChannel(_)) => CommandError::Disconnected,
        IdeviceError::Timeout => CommandError::Timeout,
        _ => CommandError::Rejected,
    }
}

impl CommandError {
    pub fn is_transient(&self) -> bool {
        matches!(self, Self::Disconnected | Self::Timeout)
    }
}

pub async fn send<R: ReadWrite>(
    channel: &mut Channel<'_, R>,
    requests: &LocationRequests,
    method: &str,
    arguments: Option<Vec<AuxValue>>,
    limit: Duration,
) -> Result<(), CommandError> {
    timeout(limit, async {
        let previous = requests.latest();
        channel
            .call_method(Some(method), arguments, true)
            .await
            .map_err(transport_error)?;
        let request = requests
            .latest()
            .filter(|request| Some(*request) != previous)
            .ok_or(CommandError::Rejected)?;
        loop {
            let reply = channel.read_message().await.map_err(transport_error)?;
            if let Some(result) = classify_reply(request, &reply) {
                return result;
            }
        }
    })
    .await
    .map_err(|_| CommandError::Timeout)?
}

fn classify_reply(request: Request, reply: &Message) -> Option<Result<(), CommandError>> {
    // idevice 2bc58aa exposes typed Message/MessageHeader but these getters and
    // the payload discriminator are crate-private. Serialize just the headers.
    let header = reply.message_header.serialize();
    if reply.message_header.channel != request.channel
        || u32_at(&header, 16) != request.identifier
        || u32_at(&header, 20) != 1
        || u32_at(&header, 28) != 0
    {
        return None;
    }
    let raw = reply.raw_data.as_deref();
    let void = reply.aux.is_none()
        && match reply.payload_header.serialize()[0] {
            DTX_OK => raw.is_none(),
            DTX_OBJECT => raw.is_none_or(is_archived_null),
            _ => false,
        };
    Some(if void {
        Ok(())
    } else {
        Err(CommandError::Rejected)
    })
}

fn is_archived_null(bytes: &[u8]) -> bool {
    // ns-keyed-archive decodes $null to an empty dictionary. Check the root
    // object in the original archive so an empty dictionary isn't accepted as nil.
    let Ok(plist::Value::Dictionary(archive)) = plist::Value::from_reader(io::Cursor::new(bytes))
    else {
        return false;
    };
    if archive.get("$archiver").and_then(plist::Value::as_string) != Some("NSKeyedArchiver") {
        return false;
    }
    let root = archive.get("$top").and_then(plist::Value::as_dictionary);
    let objects = archive.get("$objects").and_then(plist::Value::as_array);
    match (
        root.and_then(|top| top.get("root"))
            .and_then(plist::Value::as_uid),
        objects,
    ) {
        (Some(uid), Some(objects)) if uid.get() == 0 => {
            objects.first().and_then(plist::Value::as_string) == Some("$null")
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use idevice::dvt::message::MessageHeader;
    use tokio::io::{AsyncReadExt, AsyncWriteExt, DuplexStream};

    const LIMIT: Duration = Duration::from_millis(80);
    const LOCATION_CHANNEL: &str = "com.apple.instruments.server.services.LocationSimulation";

    // Synthetic DTX frames based on idevice's wire layout (not a phone capture).
    fn reply(request: Request, conversation: u32, kind: u8, data: &[u8]) -> Vec<u8> {
        let mut header = MessageHeader::new(
            0,
            1,
            request.identifier,
            conversation,
            request.channel,
            false,
        )
        .serialize();
        header[12..16].copy_from_slice(&(16 + data.len() as u32).to_le_bytes());
        header.extend_from_slice(&[kind, 0, 0, 0]);
        header.extend_from_slice(&0_u32.to_le_bytes());
        header.extend_from_slice(&(data.len() as u32).to_le_bytes());
        header.extend_from_slice(&0_u32.to_le_bytes());
        header.extend_from_slice(data);
        header
    }

    fn archive_bytes(root_value: plist::Value, root_index: u64) -> Vec<u8> {
        let mut top = plist::Dictionary::new();
        top.insert(
            "root".into(),
            plist::Value::Uid(plist::Uid::new(root_index)),
        );
        let mut archive = plist::Dictionary::new();
        archive.insert("$version".into(), plist::Value::Integer(100_000.into()));
        archive.insert(
            "$archiver".into(),
            plist::Value::String("NSKeyedArchiver".into()),
        );
        archive.insert("$top".into(), plist::Value::Dictionary(top));
        archive.insert(
            "$objects".into(),
            plist::Value::Array(vec![plist::Value::String("$null".into()), root_value]),
        );
        let mut bytes = Vec::new();
        plist::Value::Dictionary(archive)
            .to_writer_binary(&mut bytes)
            .unwrap();
        bytes
    }

    async fn read_request(peer: &mut DuplexStream) -> (Request, Message) {
        // Use idevice's parser on the same bytes the actual command produced.
        let mut header = [0; HEADER_LEN];
        peer.read_exact(&mut header).await.unwrap();
        let mut payload = vec![0; u32_at(&header, 12) as usize];
        peer.read_exact(&mut payload).await.unwrap();
        let raw = [header.as_slice(), &payload].concat();
        let message = Message::from_reader(&mut raw.as_slice()).await.unwrap();
        (
            Request {
                identifier: u32_at(&header, 16),
                channel: u32_at(&header, 24) as i32,
            },
            message,
        )
    }

    async fn exchange(
        responses: impl FnOnce(Request) -> Vec<Vec<u8>> + Send + 'static,
    ) -> Result<(), CommandError> {
        // A tiny buffer exercises the outgoing observer across partial writes.
        let (stream, mut peer) = tokio::io::duplex(19);
        let worker = tokio::spawn(async move {
            let (control, _) = read_request(&mut peer).await;
            assert_eq!(control.channel, 0);
            peer.write_all(&reply(control, 1, DTX_OK, &[]))
                .await
                .unwrap();
            let (request, message) = read_request(&mut peer).await;
            assert_eq!(request.channel, 1);
            assert_eq!(
                message.data.and_then(|data| data.into_string()).as_deref(),
                Some("stopLocationSimulation")
            );
            for response in responses(request) {
                peer.write_all(&response).await.unwrap();
            }
            // Keep the connection open so a missing reply is really a timeout.
            std::future::pending::<()>().await;
        });
        let LocationDtx {
            mut server,
            requests,
        } = LocationDtx::new(stream);
        let mut chan = timeout(
            Duration::from_secs(1),
            server.make_channel(LOCATION_CHANNEL),
        )
        .await
        .unwrap()
        .unwrap();
        let result = send(&mut chan, &requests, "stopLocationSimulation", None, LIMIT).await;
        if worker.is_finished() {
            worker.await.unwrap();
        } else {
            worker.abort();
        }
        result
    }

    #[tokio::test]
    async fn accepts_void_ack_and_archived_null() {
        assert_eq!(
            exchange(|request| vec![reply(request, 1, DTX_OK, &[])]).await,
            Ok(())
        );
        assert_eq!(
            exchange(|request| {
                let nil = archive_bytes(plist::Value::String("unused".into()), 0);
                vec![reply(request, 1, DTX_OBJECT, &nil)]
            })
            .await,
            Ok(())
        );
    }

    #[tokio::test]
    async fn rejects_an_error_or_a_non_void_object() {
        let error = archive_bytes(plist::Value::String("synthetic NSError payload".into()), 1);
        assert_eq!(
            exchange(move |request| vec![reply(request, 1, 4, &error)]).await,
            Err(CommandError::Rejected)
        );
        assert_eq!(
            exchange(|request| {
                let object = archive_bytes(plist::Value::Dictionary(plist::Dictionary::new()), 1);
                vec![reply(request, 1, DTX_OBJECT, &object)]
            })
            .await,
            Err(CommandError::Rejected)
        );
    }

    #[tokio::test]
    async fn ignores_wrong_identifier_channel_and_conversation() {
        assert_eq!(
            exchange(|request| vec![
                reply(
                    Request {
                        identifier: request.identifier + 1,
                        ..request
                    },
                    1,
                    DTX_OK,
                    &[]
                ),
                reply(
                    Request {
                        channel: 0,
                        ..request
                    },
                    1,
                    DTX_OK,
                    &[]
                ),
                reply(
                    Request {
                        channel: -request.channel,
                        ..request
                    },
                    0,
                    DTX_OK,
                    &[]
                ),
            ])
            .await,
            Err(CommandError::Timeout)
        );
        assert_eq!(
            exchange(|request| vec![
                reply(
                    Request {
                        identifier: request.identifier + 1,
                        ..request
                    },
                    1,
                    DTX_OK,
                    &[]
                ),
                reply(request, 1, DTX_OK, &[]),
            ])
            .await,
            Ok(())
        );
    }

    #[tokio::test]
    async fn accepts_fragmented_archived_null_reply() {
        assert_eq!(
            exchange(|request| {
                let nil = archive_bytes(plist::Value::String("unused".into()), 0);
                let message = reply(request, 1, DTX_OBJECT, &nil);
                let mut head = message[..HEADER_LEN].to_vec();
                head[10..12].copy_from_slice(&3_u16.to_le_bytes());
                let mut frames = vec![head.clone()];
                for (index, payload) in message[HEADER_LEN..]
                    .chunks(message[HEADER_LEN..].len().div_ceil(2))
                    .enumerate()
                {
                    head[8..10].copy_from_slice(&(index as u16 + 1).to_le_bytes());
                    head[12..16].copy_from_slice(&(payload.len() as u32).to_le_bytes());
                    frames.push([head.as_slice(), payload].concat());
                }
                frames
            })
            .await,
            Ok(())
        );
    }

    #[test]
    fn outgoing_observer_skips_payload_and_keeps_frame_boundaries() {
        fn header(identifier: u32, fragment: u16, count: u16, length: u32) -> Vec<u8> {
            let mut raw = MessageHeader::new(fragment, count, identifier, 0, 1, true).serialize();
            raw[12..16].copy_from_slice(&length.to_le_bytes());
            raw
        }
        let header_like_payload = header(99, 0, 1, 0);
        let outgoing = [
            header(2, 0, 2, header_like_payload.len() as u32),
            header(2, 1, 2, header_like_payload.len() as u32),
            header_like_payload,
        ]
        .concat();
        let mut observer = OutgoingHeaders::default();
        for write in outgoing.chunks(13) {
            observer.observe(write);
        }
        assert_eq!(
            observer.location_request,
            Some(Request {
                identifier: 2,
                channel: 1
            })
        );
        observer.observe(&header(3, 0, 1, 0));
        assert_eq!(
            observer.location_request,
            Some(Request {
                identifier: 3,
                channel: 1
            })
        );
    }

    #[tokio::test]
    async fn no_reply_cannot_confirm_clear() {
        assert_eq!(exchange(|_| vec![]).await, Err(CommandError::Timeout));
    }
}
