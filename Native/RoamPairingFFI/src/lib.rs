mod location_dtx;

use std::ffi::{CStr, CString, c_char, c_void};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use idevice::dvt::{
    message::AuxValue,
    remote_server::Channel,
};
use idevice::remote_pairing::{
    PairableHost, PairableHostInfo, PeerDevice, RemotePairingClient, RpPairingFile,
    RpPairingSocket, connect_tls_psk_tunnel_native,
};
use idevice::rsd::RsdHandshake;
use location_dtx::{CommandError, LocationDtx, LocationRequests};
use idevice::{ReadWrite, RsdService, tcp};
use tokio::net::{TcpListener, TcpSocket, TcpStream};
use tokio::time::{Instant, sleep, timeout};

const DEFAULT_HOST_NAME: &str = "Roam Control";
const DEFAULT_HOST_MODEL: &str = "Mac17,7";
const CANCELLED_ERROR: &str = "Pairing was cancelled.";
const SESSION_TIMEOUT: Duration = Duration::from_secs(15);
const LOCATION_CONNECT_TIMEOUT: Duration = Duration::from_secs(35);
const LOCATION_COMMAND_TIMEOUT: Duration = Duration::from_secs(5);
const PAIRING_ACCEPT_TIMEOUT: Duration = Duration::from_secs(90);
const PAIRING_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(90);
const LOCATION_CHANNEL: &str = "com.apple.instruments.server.services.LocationSimulation";

pub type ReadyCallback = Option<
    extern "C" fn(
        context: *mut c_void,
        service_identifier: *const c_char,
        port: u16,
        txt_keys: *const *const c_char,
        txt_values: *const *const c_char,
        txt_count: usize,
    ),
>;

pub type PinCallback = Option<extern "C" fn(context: *mut c_void, pin: *const c_char)>;

#[repr(C)]
pub struct RemotePairingSession {
    cancelled: Arc<AtomicBool>,
}

#[repr(C)]
pub struct LocationSession {
    cancelled: Arc<AtomicBool>,
    coordinates: Arc<Mutex<LocationCoordinates>>,
    // Once a write may have reached the device, a panic cannot be reported as a clean cancellation.
    needs_clear: Arc<AtomicBool>,
}

#[derive(Clone, Copy, PartialEq)]
struct LocationCoordinates {
    latitude: f64,
    longitude: f64,
}

impl LocationCoordinates {
    fn validated(latitude: f64, longitude: f64) -> Result<Self, String> {
        if latitude.is_finite()
            && longitude.is_finite()
            && (-90.0..=90.0).contains(&latitude)
            && (-180.0..=180.0).contains(&longitude)
        {
            Ok(Self {
                latitude,
                longitude,
            })
        } else {
            Err("That location is outside the valid coordinate range.".to_string())
        }
    }
}

#[repr(C)]
pub struct RemotePairingResult {
    pub error_message: *mut c_char,
    pub device_name: *mut c_char,
    pub device_model: *mut c_char,
    pub device_udid: *mut c_char,
    pub pairing_record: *mut u8,
    pub pairing_record_length: usize,
    pub host_alt_irk: *mut u8,
    pub host_alt_irk_length: usize,
}

#[repr(C)]
pub struct LocationResult {
    pub error_message: *mut c_char,
    pub clear_status: LocationClearStatus,
    pub retryable: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LocationClearStatus {
    NotNeeded = 0,
    Confirmed = 1,
    Unconfirmed = 2,
}

impl LocationResult {
    fn empty() -> Self {
        Self {
            error_message: ptr::null_mut(),
            clear_status: LocationClearStatus::NotNeeded,
            retryable: 0,
        }
    }
}

#[derive(Debug)]
struct LocationFailure {
    message: String,
    retryable: bool,
}

impl LocationFailure {
    fn new(message: impl Into<String>, retryable: bool) -> Self {
        Self {
            message: message.into(),
            retryable,
        }
    }
}

impl From<String> for LocationFailure {
    fn from(message: String) -> Self {
        Self::new(message, false)
    }
}

pub type LocationStartedCallback = Option<extern "C" fn(context: *mut c_void)>;

impl RemotePairingResult {
    fn empty() -> Self {
        Self {
            error_message: ptr::null_mut(),
            device_name: ptr::null_mut(),
            device_model: ptr::null_mut(),
            device_udid: ptr::null_mut(),
            pairing_record: ptr::null_mut(),
            pairing_record_length: 0,
            host_alt_irk: ptr::null_mut(),
            host_alt_irk_length: 0,
        }
    }
}

struct CallbackSet {
    ready: ReadyCallback,
    pin: PinCallback,
    context: *mut c_void,
}

unsafe impl Send for CallbackSet {}

struct CompletedPairing {
    device_name: String,
    device_model: String,
    device_udid: String,
    pairing_record: Vec<u8>,
    host_alt_irk: Vec<u8>,
}

#[unsafe(no_mangle)]
pub extern "C" fn rc_remote_pairing_session_create() -> *mut RemotePairingSession {
    Box::into_raw(Box::new(RemotePairingSession {
        cancelled: Arc::new(AtomicBool::new(false)),
    }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_remote_pairing_session_cancel(session: *mut RemotePairingSession) {
    if let Some(session) = unsafe { session.as_ref() } {
        session.cancelled.store(true, Ordering::Release);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_remote_pairing_session_run(
    session: *mut RemotePairingSession,
    host_name: *const c_char,
    host_model: *const c_char,
    ready_callback: ReadyCallback,
    pin_callback: PinCallback,
    context: *mut c_void,
    result: *mut RemotePairingResult,
) -> i32 {
    if session.is_null() || result.is_null() {
        return 2;
    }

    unsafe { *result = RemotePairingResult::empty() };

    let session = unsafe { &*session };

    let host_name = unsafe { optional_c_string(host_name, DEFAULT_HOST_NAME) };
    let host_model = unsafe { optional_c_string(host_model, DEFAULT_HOST_MODEL) };
    let callbacks = CallbackSet {
        ready: ready_callback,
        pin: pin_callback,
        context,
    };
    let cancellation = Arc::clone(&session.cancelled);

    let execution = catch_unwind(AssertUnwindSafe(|| {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .map_err(|_| "Roam Control could not start its pairing engine.")?;

        runtime.block_on(run_pairing(host_name, host_model, callbacks, cancellation))
    }));

    match execution {
        Ok(Ok(completed)) => {
            unsafe { write_success(&mut *result, completed) };
            0
        }
        Ok(Err(PairingFailure::Expired)) => 3,
        Ok(Err(PairingFailure::Other(message))) => {
            unsafe { (*result).error_message = owned_c_string(message) };
            1
        }
        Err(_) => {
            unsafe {
                (*result).error_message =
                    owned_c_string("The pairing engine stopped unexpectedly.");
            }
            1
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_remote_pairing_result_destroy(result: *mut RemotePairingResult) {
    let Some(result) = (unsafe { result.as_mut() }) else {
        return;
    };

    for value in [
        result.error_message,
        result.device_name,
        result.device_model,
        result.device_udid,
    ] {
        if !value.is_null() {
            unsafe { drop(CString::from_raw(value)) };
        }
    }

    unsafe {
        destroy_byte_buffer(result.pairing_record, result.pairing_record_length);
        destroy_byte_buffer(result.host_alt_irk, result.host_alt_irk_length);
    }
    *result = RemotePairingResult::empty();
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_remote_pairing_session_destroy(session: *mut RemotePairingSession) {
    if !session.is_null() {
        unsafe { drop(Box::from_raw(session)) };
    }
}

/// Returns 1 when an mDNS remote-pairing announcement belongs to the device
/// represented by this pairing record, and 0 for a non-match or malformed data.
/// The full pair-verify handshake remains the final identity check.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_pairing_record_matches_service(
    pairing_record: *const u8,
    pairing_record_length: usize,
    service_identifier: *const c_char,
    auth_tag: *const c_char,
) -> i32 {
    if pairing_record.is_null()
        || pairing_record_length == 0
        || service_identifier.is_null()
        || auth_tag.is_null()
    {
        return 0;
    }

    let execution = catch_unwind(AssertUnwindSafe(|| {
        let pairing_record =
            unsafe { std::slice::from_raw_parts(pairing_record, pairing_record_length) };
        let Ok(pairing_file) = RpPairingFile::from_bytes(pairing_record) else {
            return false;
        };
        let Some(alt_irk) = device_identity(&pairing_file) else {
            return false;
        };
        let Ok(service_identifier) = (unsafe { CStr::from_ptr(service_identifier) }).to_str()
        else {
            return false;
        };
        let Ok(auth_tag) = (unsafe { CStr::from_ptr(auth_tag) }).to_str() else {
            return false;
        };

        PeerDevice::validate_auth_tag(alt_irk, service_identifier.trim(), auth_tag.trim())
    }));

    matches!(execution, Ok(true)) as i32
}

#[unsafe(no_mangle)]
pub extern "C" fn rc_location_session_create() -> *mut LocationSession {
    Box::into_raw(Box::new(LocationSession {
        cancelled: Arc::new(AtomicBool::new(false)),
        coordinates: Arc::new(Mutex::new(LocationCoordinates {
            latitude: 0.0,
            longitude: 0.0,
        })),
        needs_clear: Arc::new(AtomicBool::new(false)),
    }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_location_session_cancel(session: *mut LocationSession) {
    if let Some(session) = unsafe { session.as_ref() } {
        session.cancelled.store(true, Ordering::Release);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_location_session_update(
    session: *mut LocationSession,
    latitude: f64,
    longitude: f64,
) -> i32 {
    let Some(session) = (unsafe { session.as_ref() }) else {
        return 2;
    };
    let Ok(coordinates) = LocationCoordinates::validated(latitude, longitude) else {
        return 1;
    };
    let Ok(mut current) = session.coordinates.lock() else {
        return 2;
    };
    *current = coordinates;
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_location_session_run(
    session: *mut LocationSession,
    pairing_record: *const u8,
    pairing_record_length: usize,
    peer_address: *const c_char,
    tunnel_interface_index: u32,
    remote_pairing_port: u16,
    service_identifier: *const c_char,
    auth_tag: *const c_char,
    latitude: f64,
    longitude: f64,
    clear_only: i32,
    started_callback: LocationStartedCallback,
    context: *mut c_void,
    result: *mut LocationResult,
) -> i32 {
    if session.is_null()
        || result.is_null()
        || pairing_record.is_null()
        || pairing_record_length == 0
    {
        return 2;
    }

    unsafe { *result = LocationResult::empty() };

    let session = unsafe { &*session };
    let clear_only = clear_only != 0;
    let needs_clear = Arc::clone(&session.needs_clear);
    let pairing_record =
        unsafe { std::slice::from_raw_parts(pairing_record, pairing_record_length).to_vec() };
    let peer_address = unsafe { optional_c_string(peer_address, "10.7.0.1") };
    let service_identifier = unsafe { optional_c_string(service_identifier, "") };
    let auth_tag = unsafe { optional_c_string(auth_tag, "") };
    let cancellation = Arc::clone(&session.cancelled);
    let coordinates = Arc::clone(&session.coordinates);
    if let Ok(mut current) = coordinates.lock() {
        *current = LocationCoordinates {
            latitude,
            longitude,
        };
    }
    let callback_context = context as usize;

    let execution = catch_unwind(AssertUnwindSafe(|| {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(3)
            .enable_all()
            .build()
            .map_err(|_| {
                LocationFailure::new("Roam Control could not start its device session.", false)
            });

        let runtime = match runtime {
            Ok(runtime) => runtime,
            Err(error) => {
                return (
                    Err(error),
                    if clear_only {
                        LocationClearStatus::Unconfirmed
                    } else {
                        LocationClearStatus::NotNeeded
                    },
                );
            }
        };
        runtime.block_on(run_location_session(
            pairing_record,
            peer_address,
            tunnel_interface_index,
            remote_pairing_port,
            service_identifier,
            auth_tag,
            coordinates,
            clear_only,
            Arc::clone(&needs_clear),
            started_callback,
            callback_context,
            cancellation,
        ))
    }));

    let fallback_status = if clear_only || needs_clear.load(Ordering::Acquire) {
        LocationClearStatus::Unconfirmed
    } else {
        LocationClearStatus::NotNeeded
    };
    let (outcome, status) = execution.unwrap_or_else(|_| {
        (
            Err(LocationFailure::new(
                "The location session stopped unexpectedly.",
                false,
            )),
            fallback_status,
        )
    });
    let result = unsafe { &mut *result };
    result.clear_status = status;
    match outcome {
        Ok(()) => 0,
        Err(failure) => {
            result.retryable = i32::from(failure.retryable);
            result.error_message = owned_c_string(failure.message);
            1
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_location_result_destroy(result: *mut LocationResult) {
    let Some(result) = (unsafe { result.as_mut() }) else {
        return;
    };
    if !result.error_message.is_null() {
        unsafe { drop(CString::from_raw(result.error_message)) };
    }
    *result = LocationResult::empty();
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rc_location_session_destroy(session: *mut LocationSession) {
    if !session.is_null() {
        unsafe { drop(Box::from_raw(session)) };
    }
}

enum PairingFailure {
    Other(String),
    Expired,
}

impl From<String> for PairingFailure {
    fn from(message: String) -> Self { Self::Other(message) }
}

impl From<&str> for PairingFailure {
    fn from(message: &str) -> Self { Self::Other(message.to_owned()) }
}

async fn run_pairing(
    host_name: String,
    host_model: String,
    callbacks: CallbackSet,
    cancellation: Arc<AtomicBool>,
) -> Result<CompletedPairing, PairingFailure> {
    if cancellation.load(Ordering::Acquire) {
        return Err(CANCELLED_ERROR.into());
    }

    let listener = TcpListener::bind(SocketAddr::new(Ipv4Addr::UNSPECIFIED.into(), 0))
        .await
        .map_err(|_| "Roam Control could not open a local pairing connection.".to_string())?;
    let port = listener
        .local_addr()
        .map_err(|_| "Roam Control could not determine its pairing port.".to_string())?
        .port();

    let mut pairing_record = RpPairingFile::generate(&host_name);
    let host_info = PairableHostInfo::generate(&host_name, &host_model);
    let host_alt_irk = host_info.alt_irk.to_vec();
    let service_identifier = pairing_record.identifier.clone();

    publish_ready_callback(&callbacks, &service_identifier, port, &host_info);

    let (stream, _) = tokio::select! {
        accepted = timeout(PAIRING_ACCEPT_TIMEOUT, listener.accept()) => {
            accepted.map_err(|_| PairingFailure::Expired)?
                .map_err(|_| "The iPhone could not connect to Roam Control.".to_string())?
        }
        _ = wait_for_cancellation(Arc::clone(&cancellation)) => {
            return Err(CANCELLED_ERROR.into());
        }
    };

    let pin_callback = callbacks.pin;
    let callback_context = callbacks.context as usize;
    let socket = RpPairingSocket::new_device(stream);
    let mut pairable_host = PairableHost::new(socket, host_info);

    let peer = tokio::select! {
        outcome = timeout(PAIRING_HANDSHAKE_TIMEOUT, pairable_host.accept(&mut pairing_record, move |pin| async move {
            if let Some(callback) = pin_callback
                && let Ok(pin) = CString::new(pin)
            {
                callback(callback_context as *mut c_void, pin.as_ptr());
            }
        })) => {
            outcome.map_err(|_| PairingFailure::Expired)?
                .map_err(|error| friendly_pairing_error(&error.to_string()))?
        }
        _ = wait_for_cancellation(Arc::clone(&cancellation)) => {
            return Err(CANCELLED_ERROR.into());
        }
    };

    Ok(CompletedPairing {
        device_name: peer.name,
        device_model: peer.model,
        device_udid: peer.remotepairing_udid,
        pairing_record: pairing_record.to_bytes(),
        host_alt_irk,
    })
}

#[allow(clippy::too_many_arguments)]
async fn run_location_session(
    pairing_record_bytes: Vec<u8>,
    peer_address: String,
    tunnel_interface_index: u32,
    remote_pairing_port: u16,
    service_identifier: String,
    auth_tag: String,
    coordinates: Arc<Mutex<LocationCoordinates>>,
    clear_only: bool,
    needs_clear: Arc<AtomicBool>,
    started_callback: LocationStartedCallback,
    callback_context: usize,
    cancellation: Arc<AtomicBool>,
) -> (Result<(), LocationFailure>, LocationClearStatus) {
    let initial_status = if clear_only {
        LocationClearStatus::Unconfirmed
    } else {
        LocationClearStatus::NotNeeded
    };
    let mut clear_confirmed = false;
    let result = async {
        if cancellation.load(Ordering::Acquire) {
            return Ok(());
        }
        let service_identifier = service_identifier.trim();
        let auth_tag = auth_tag.trim();
        if remote_pairing_port == 0 || service_identifier.is_empty() || auth_tag.is_empty() {
            return Err(LocationFailure::new(
                "Roam Control could not identify this iPhone's pairing service.",
                false,
            ));
        }
        let mut pairing_file = RpPairingFile::from_bytes(&pairing_record_bytes).map_err(|_| {
            LocationFailure::new("The saved pairing record could not be read.", false)
        })?;
        let alt_irk = device_identity(&pairing_file).ok_or_else(|| {
            LocationFailure::new(
                "The saved pairing record is missing a valid device identity (alt_irk).",
                false,
            )
        })?;
        if !PeerDevice::validate_auth_tag(alt_irk, service_identifier, auth_tag) {
            return Err(LocationFailure::new(
                "The discovered device did not match the paired iPhone.",
                false,
            ));
        }

        let connect = async {
            let peer_ip: IpAddr = peer_address.parse().map_err(|_| {
                LocationFailure::new("LocalDevVPN returned an invalid device address.", false)
            })?;
            let pairing_address = SocketAddr::new(peer_ip, remote_pairing_port);
            let stream = timeout(
                SESSION_TIMEOUT,
                connect_to_tunnel(pairing_address, tunnel_interface_index),
            )
            .await
            .map_err(|_| {
                LocationFailure::new(
                    "LocalDevVPN did not make the iPhone connection available in time.",
                    true,
                )
            })?
            .map_err(|_| {
                LocationFailure::new(
                    "Roam Control could not reach the iPhone through LocalDevVPN.",
                    true,
                )
            })?;

            let socket = RpPairingSocket::new(stream);
            let mut remote_pairing = RemotePairingClient::new(socket, DEFAULT_HOST_NAME);
            timeout(SESSION_TIMEOUT, remote_pairing.attempt_pair_verify())
                .await
                .map_err(|_| {
                    LocationFailure::new("The paired iPhone did not respond in time.", true)
                })?
                .map_err(|_| {
                    LocationFailure::new("The iPhone rejected the saved pairing session.", false)
                })?;
            timeout(
                SESSION_TIMEOUT,
                remote_pairing.validate_pairing(&mut pairing_file),
            )
            .await
            .map_err(|_| LocationFailure::new("Pairing verification took too long.", true))?
            .map_err(|_| {
                LocationFailure::new(
                    "The saved pairing is no longer valid. Reset Device Setup and pair again.",
                    false,
                )
            })?;

            let tunnel_port = timeout(SESSION_TIMEOUT, remote_pairing.create_tcp_listener())
                .await
                .map_err(|_| {
                    LocationFailure::new(
                        "The iPhone did not create its secure tunnel in time.",
                        true,
                    )
                })?
                .map_err(|_| {
                    LocationFailure::new("The iPhone could not create its secure tunnel.", true)
                })?;
            let tunnel_stream = timeout(
                SESSION_TIMEOUT,
                connect_to_tunnel(
                    SocketAddr::new(peer_ip, tunnel_port),
                    tunnel_interface_index,
                ),
            )
            .await
            .map_err(|_| {
                LocationFailure::new("LocalDevVPN did not open the secure tunnel in time.", true)
            })?
            .map_err(|_| {
                LocationFailure::new(
                    "Roam Control could not open the secure device tunnel.",
                    true,
                )
            })?;
            let tunnel = timeout(
                SESSION_TIMEOUT,
                connect_tls_psk_tunnel_native(tunnel_stream, remote_pairing.encryption_key()),
            )
            .await
            .map_err(|_| {
                LocationFailure::new("The encrypted device tunnel took too long to start.", true)
            })?
            .map_err(|_| {
                LocationFailure::new("Roam Control could not secure the device tunnel.", true)
            })?;

            let client_ip: IpAddr = tunnel.info.client_address.parse().map_err(|_| {
                LocationFailure::new("The iPhone returned an invalid tunnel address.", true)
            })?;
            let server_ip: IpAddr = tunnel.info.server_address.parse().map_err(|_| {
                LocationFailure::new("The iPhone returned an invalid service address.", true)
            })?;
            let rsd_port = tunnel.info.server_rsd_port;
            let adapter =
                tcp::adapter::Adapter::new(Box::new(tunnel.into_inner()), client_ip, server_ip);
            let mut handle = adapter.to_async_handle();

            let rsd_stream = timeout(SESSION_TIMEOUT, handle.connect(rsd_port))
                .await
                .map_err(|_| {
                    LocationFailure::new(
                        "The iPhone's service directory took too long to respond.",
                        true,
                    )
                })?
                .map_err(|_| {
                    LocationFailure::new(
                        "Roam Control could not open the iPhone's service directory.",
                        true,
                    )
                })?;
            let mut handshake = timeout(SESSION_TIMEOUT, RsdHandshake::new(rsd_stream))
                .await
                .map_err(|_| {
                    LocationFailure::new("The iPhone's service handshake took too long.", true)
                })?
                .map_err(|_| {
                    LocationFailure::new(
                        "Roam Control could not complete the iPhone service handshake.",
                        true,
                    )
                })?;
            let mut dvt = timeout(
                SESSION_TIMEOUT,
                LocationDtx::connect_rsd(&mut handle, &mut handshake),
            )
            .await
            .map_err(|_| LocationFailure::new("The location service took too long to open.", true))?
            .map_err(|_| {
                LocationFailure::new(
                    "The iPhone did not make its location service available.",
                    true,
                )
            })?;
            timeout(SESSION_TIMEOUT, dvt.server.read_message(0))
                .await
                .map_err(|_| {
                    LocationFailure::new("The location service did not become ready in time.", true)
                })?
                .map_err(|_| {
                    LocationFailure::new(
                        "The iPhone's location service did not become ready.",
                        true,
                    )
                })?;

            Ok::<_, LocationFailure>(dvt)
        };
        let LocationDtx { server: mut dvt, requests } = tokio::select! {
            biased;
            _ = wait_for_cancellation(Arc::clone(&cancellation)) => return Ok(()),
            response = timeout(LOCATION_CONNECT_TIMEOUT, connect) => {
                response.map_err(|_| LocationFailure::new("The device connection took too long to open.", true))??
            }
        };

        let mut applied = if clear_only {
            None
        } else {
            Some(current_coordinates(&coordinates)?)
        };
        let mut location = tokio::select! {
            biased;
            _ = wait_for_cancellation(Arc::clone(&cancellation)) => return Ok(()),
            response = timeout(SESSION_TIMEOUT, dvt.make_channel(LOCATION_CHANNEL)) => {
                response.map_err(|_| LocationFailure::new("The location controls took too long to open.", true))?
                    .map_err(|_| LocationFailure::new("Roam Control could not open the iPhone's location controls.", true))?
            }
        };
        if let Some(initial) = &mut applied {
            if cancellation.load(Ordering::Acquire) {
                return Ok(());
            }
            needs_clear.store(true, Ordering::Release);
            let apply = apply_location(
                &mut location,
                &requests,
                initial,
                &coordinates,
                &cancellation,
                started_callback,
                callback_context,
            )
            .await;
            if let Err(error) = apply {
                // A timed-out write may still have changed the device, and its late reply
                // cannot acknowledge a clear on a fresh channel.
                let clear = timeout(LOCATION_COMMAND_TIMEOUT, async {
                    let mut fresh = dvt.make_channel(LOCATION_CHANNEL).await.map_err(|_| ())?;
                    location_dtx::send(&mut fresh, &requests, "stopLocationSimulation", None, LOCATION_COMMAND_TIMEOUT)
                        .await.map_err(|_| ())
                })
                .await;
                match clear {
                    Ok(Ok(())) => {
                        needs_clear.store(false, Ordering::Release);
                        clear_confirmed = true;
                    }
                    _ => return Err(clear_failure(Some(error))),
                }
                return Err(error);
            }
        }

        let clear = location_dtx::send(&mut location, &requests, "stopLocationSimulation", None, LOCATION_COMMAND_TIMEOUT).await;
        match clear {
            Ok(()) => {
                needs_clear.store(false, Ordering::Release);
                clear_confirmed = true;
                Ok(())
            }
            Err(error) => {
                let mut failure = clear_failure(None);
                // Retrying a user's stop may only send another clear, never a set.
                failure.retryable = error.is_transient();
                Err(failure)
            },
        }
    };

    // Recovery must still be considered pending if cancelled before contacting the device.
    let result = result.await;
    let status = if clear_confirmed {
        LocationClearStatus::Confirmed
    } else if needs_clear.load(Ordering::Acquire) {
        LocationClearStatus::Unconfirmed
    } else {
        initial_status
    };
    (result, status)
}

// Both the discovery probe and later TCP connections must use LocalDevVPN's
// interface even if a concurrently active Personal VPN owns the default route.
async fn connect_to_tunnel(
    address: SocketAddr,
    interface_index: u32,
) -> std::io::Result<TcpStream> {
    let socket = TcpSocket::new_v4()?;
    #[cfg(target_os = "ios")]
    {
        use std::os::fd::AsRawFd;

        if interface_index == 0 {
            return Err(std::io::Error::other(
                "LocalDevVPN interface is unavailable",
            ));
        }
        let result = unsafe {
            libc::setsockopt(
                socket.as_raw_fd(),
                libc::IPPROTO_IP,
                libc::IP_BOUND_IF,
                (&interface_index as *const u32).cast(),
                std::mem::size_of::<u32>() as libc::socklen_t,
            )
        };
        if result != 0 {
            return Err(std::io::Error::last_os_error());
        }
    }
    #[cfg(not(target_os = "ios"))]
    let _ = interface_index;
    socket.connect(address).await
}

async fn apply_location<R: ReadWrite>(
    location: &mut Channel<'_, R>,
    requests: &LocationRequests,
    applied: &mut LocationCoordinates,
    coordinates: &Arc<Mutex<LocationCoordinates>>,
    cancellation: &AtomicBool,
    started_callback: LocationStartedCallback,
    callback_context: usize,
) -> Result<(), LocationFailure> {
    write_location(
        location,
        requests,
        *applied,
        "The iPhone did not accept the selected location.",
    )
    .await?;
    if !cancellation.load(Ordering::Acquire)
        && let Some(callback) = started_callback
    {
        callback(callback_context as *mut c_void);
    }

    let mut last_refresh = Instant::now();
    while !cancellation.load(Ordering::Acquire) {
        sleep(Duration::from_millis(200)).await;
        if cancellation.load(Ordering::Acquire) {
            break;
        }
        let latest = current_coordinates(coordinates)?;
        if latest != *applied || last_refresh.elapsed() >= Duration::from_secs(4) {
            write_location(
                location,
                requests,
                latest,
                "The iPhone ended the active location session.",
            )
            .await?;
            *applied = latest;
            last_refresh = Instant::now();
        }
    }
    Ok(())
}

async fn write_location<R: ReadWrite>(
    location: &mut Channel<'_, R>,
    requests: &LocationRequests,
    coordinates: LocationCoordinates,
    error: &str,
) -> Result<(), LocationFailure> {
    location_dtx::send(
        location,
        requests,
        "simulateLocationWithLatitude:longitude:",
        Some(vec![
            AuxValue::archived_value(coordinates.latitude),
            AuxValue::archived_value(coordinates.longitude),
        ]),
        LOCATION_COMMAND_TIMEOUT,
    ).await.map_err(|outcome| {
        let message = if outcome == CommandError::Timeout {
            format!("{error} The location command timed out.")
        } else {
            error.to_owned()
        };
        LocationFailure::new(message, outcome.is_transient())
    })
}

fn clear_failure(prior: Option<LocationFailure>) -> LocationFailure {
    let retryable = prior.as_ref().is_some_and(|error| error.retryable);
    let message = "The iPhone did not confirm that its simulated location was cleared. Reconnect and restore your real location.";
    LocationFailure::new(
        prior.map_or_else(
            || message.to_string(),
            |error| format!("{} {message}", error.message),
        ),
        retryable,
    )
}

fn device_identity(pairing_file: &RpPairingFile) -> Option<&[u8]> {
    pairing_file.alt_irk().filter(|key| key.len() == 16)
}

fn current_coordinates(
    coordinates: &Arc<Mutex<LocationCoordinates>>,
) -> Result<LocationCoordinates, String> {
    let current = coordinates
        .lock()
        .map_err(|_| "Roam Control could not update the active location.".to_string())?;
    LocationCoordinates::validated(current.latitude, current.longitude)
}

async fn wait_for_cancellation(cancelled: Arc<AtomicBool>) {
    while !cancelled.load(Ordering::Acquire) {
        sleep(Duration::from_millis(150)).await;
    }
}

fn publish_ready_callback(
    callbacks: &CallbackSet,
    service_identifier: &str,
    port: u16,
    host_info: &PairableHostInfo,
) {
    let Some(callback) = callbacks.ready else {
        return;
    };
    let Ok(service_identifier) = CString::new(service_identifier) else {
        return;
    };

    let records = host_info.mdns_txt_records(service_identifier.to_str().unwrap_or_default());
    let keys: Vec<CString> = records
        .iter()
        .filter_map(|(key, _)| CString::new(key.as_str()).ok())
        .collect();
    let values: Vec<CString> = records
        .iter()
        .filter_map(|(_, value)| CString::new(value.as_str()).ok())
        .collect();

    if keys.len() != records.len() || values.len() != records.len() {
        return;
    }

    let key_pointers: Vec<*const c_char> = keys.iter().map(|value| value.as_ptr()).collect();
    let value_pointers: Vec<*const c_char> = values.iter().map(|value| value.as_ptr()).collect();

    callback(
        callbacks.context,
        service_identifier.as_ptr(),
        port,
        key_pointers.as_ptr(),
        value_pointers.as_ptr(),
        records.len(),
    );
}

fn friendly_pairing_error(raw: &str) -> String {
    let lowercased = raw.to_lowercase();
    if lowercased.contains("srp") || lowercased.contains("auth") {
        "The code was not accepted. Start pairing again and enter the new code.".to_string()
    } else if lowercased.contains("connection")
        || lowercased.contains("broken pipe")
        || lowercased.contains("unexpected eof")
    {
        "The iPhone ended the pairing connection. Start pairing again when you are ready."
            .to_string()
    } else {
        "The iPhone could not finish pairing. Please try again.".to_string()
    }
}

unsafe fn optional_c_string(value: *const c_char, fallback: &str) -> String {
    if value.is_null() {
        return fallback.to_string();
    }

    unsafe { CStr::from_ptr(value) }
        .to_str()
        .ok()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(fallback)
        .to_string()
}

unsafe fn write_success(result: &mut RemotePairingResult, completed: CompletedPairing) {
    result.device_name = owned_c_string(completed.device_name);
    result.device_model = owned_c_string(completed.device_model);
    result.device_udid = owned_c_string(completed.device_udid);

    let (pairing_record, pairing_record_length) = owned_byte_buffer(completed.pairing_record);
    result.pairing_record = pairing_record;
    result.pairing_record_length = pairing_record_length;

    let (host_alt_irk, host_alt_irk_length) = owned_byte_buffer(completed.host_alt_irk);
    result.host_alt_irk = host_alt_irk;
    result.host_alt_irk_length = host_alt_irk_length;
}

fn owned_c_string(value: impl Into<Vec<u8>>) -> *mut c_char {
    CString::new(value).unwrap_or_default().into_raw()
}

fn owned_byte_buffer(value: Vec<u8>) -> (*mut u8, usize) {
    let mut value = value.into_boxed_slice();
    let length = value.len();
    let pointer = value.as_mut_ptr();
    std::mem::forget(value);
    (pointer, length)
}

unsafe fn destroy_byte_buffer(pointer: *mut u8, length: usize) {
    if !pointer.is_null() && length > 0 {
        unsafe { ptr::write_bytes(pointer, 0, length) };
        let slice = ptr::slice_from_raw_parts_mut(pointer, length);
        unsafe { drop(Box::from_raw(slice)) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run_cancelled_location(clear_only: bool) -> (i32, LocationClearStatus) {
        let session = rc_location_session_create();
        let mut result = LocationResult::empty();
        let record = [0_u8]; // Cancellation must take effect before parsing or connecting.
        unsafe {
            rc_location_session_cancel(session);
            let code = rc_location_session_run(
                session,
                record.as_ptr(),
                record.len(),
                ptr::null(),
                0,
                1,
                ptr::null(),
                ptr::null(),
                0.0,
                0.0,
                i32::from(clear_only),
                None,
                ptr::null_mut(),
                &mut result,
            );
            let status = result.clear_status;
            rc_location_result_destroy(&mut result);
            rc_location_session_destroy(session);
            (code, status)
        }
    }

    #[test]
    fn pre_cancelled_start_never_attempts_to_connect_or_clear() {
        assert_eq!(
            run_cancelled_location(false),
            (0, LocationClearStatus::NotNeeded)
        );
    }

    #[test]
    fn pre_cancelled_restore_does_not_confirm_a_clear() {
        assert_eq!(
            run_cancelled_location(true),
            (0, LocationClearStatus::Unconfirmed)
        );
    }

    #[test]
    fn pre_cancelled_pairing_never_waits_for_a_peer() {
        let session = rc_remote_pairing_session_create();
        let mut result = RemotePairingResult::empty();
        unsafe {
            rc_remote_pairing_session_cancel(session);
            let code = rc_remote_pairing_session_run(
                session,
                ptr::null(),
                ptr::null(),
                None,
                None,
                ptr::null_mut(),
                &mut result,
            );
            assert_eq!(code, 1);
            assert_eq!(
                CStr::from_ptr(result.error_message).to_str().unwrap(),
                CANCELLED_ERROR
            );
            rc_remote_pairing_result_destroy(&mut result);
            rc_remote_pairing_session_destroy(session);
        }
    }

    #[test]
    fn discovery_requires_a_16_byte_device_identity() {
        let mut pairing = RpPairingFile::generate("test");
        let identifier = c"2BE6E510-0325-4365-923E-B14C6F57DB3A";
        let tag = c"kXjlTr2l";
        let matches = |pairing: &RpPairingFile| {
            let bytes = pairing.to_bytes();
            unsafe {
                rc_pairing_record_matches_service(
                    bytes.as_ptr(),
                    bytes.len(),
                    identifier.as_ptr(),
                    tag.as_ptr(),
                ) == 1
            }
        };
        assert!(!matches(&pairing));
        pairing.alt_irk = Some(vec![0; 15]);
        assert!(!matches(&pairing));
        pairing.alt_irk = Some(
            [
                0x32, 0x0a, 0x7a, 0x64, 0x63, 0xf3, 0x5c, 0xcd, 0xa4, 0xbb, 0xd6, 0xeb, 0xe3, 0xab,
                0xec, 0x8b,
            ]
            .to_vec(),
        );
        assert!(matches(&pairing));
    }
}
