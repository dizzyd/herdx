use super::*;

/// A transport whose only job is to be armed, and to say whether anything
/// ever broke it.
///
/// `Interrupt::Local` wants a real socket pair — the point of it is that
/// shutting one half down returns the other half's blocked read — so these
/// use one rather than a stub. Whether the peer saw the shutdown is the
/// honest reading of "was this connection broken".
fn socket_pair() -> (std::os::unix::net::UnixStream, std::os::unix::net::UnixStream) {
    let (near, far) = std::os::unix::net::UnixStream::pair().expect("socket pair");
    // Set now rather than when it is read, because waking an interrupt
    // drops it, and macOS refuses `setsockopt` on a socket whose peer has
    // closed — the very state these tests are trying to observe.
    far.set_read_timeout(Some(std::time::Duration::from_millis(250)))
        .expect("read timeout");
    (near, far)
}

/// Whether the connection was broken, read from the far end rather than
/// from our own record of having asked.
fn was_broken(peer: &std::os::unix::net::UnixStream) -> bool {
    use std::io::Read;
    // A shutdown or closed half reads as end-of-stream; a live one has
    // nothing to say and times out instead.
    let mut byte = [0u8; 1];
    matches!((&mut { peer }).read(&mut byte), Ok(0))
}

/// The window that let a wake go missing: a nudge lands after the
/// transport exists but before the loop has armed it.
///
/// Nothing is there to interrupt, so the nudge used to be dropped on the
/// floor and `arm` would then accept the condemned transport — leaving the
/// loop parked in a read on a path already known to be dead, with nothing
/// pending to break it out. Recovery fell back to ssh's keepalive timeout,
/// which is the wait the nudge exists to skip.
#[test]
fn a_transport_built_before_a_nudge_is_refused_after_it() {
    let halt = Halt::default();
    let began = halt.generation();
    let (near, far) = socket_pair();

    halt.nudge();

    assert!(
        !halt.arm(began, crate::endpoint::Interrupt::Local(near)),
        "armed a transport the nudge had already condemned"
    );
    // Refusing is only useful because it is what makes the attempt give
    // up; an attempt that proceeded unarmed would be the same bug.
    assert_eq!(
        halt.rest(LONGEST_BACKOFF, began),
        Rested::Woken,
        "the refused attempt did not lead to a fresh one"
    );
    drop(far);
}

/// The same window, one step later: a nudge after the transport is armed
/// has something to break, and must break it.
#[test]
fn a_nudge_breaks_a_transport_that_was_armed_in_time() {
    let halt = Halt::default();
    let began = halt.generation();
    let (near, far) = socket_pair();

    assert!(halt.arm(began, crate::endpoint::Interrupt::Local(near)));
    halt.nudge();

    assert!(
        was_broken(&far),
        "the live connection survived the nudge, so the read would not return"
    );
}

/// A wake that arrives while an attempt is still failing has no waiter to
/// notify, and used to be slept through for the full backoff.
#[test]
fn a_wake_already_in_hand_is_not_slept_through() {
    let halt = Halt::default();
    let began = halt.generation();

    halt.nudge();

    let started = std::time::Instant::now();
    let rested = halt.rest(LONGEST_BACKOFF, began);
    let took = started.elapsed();

    assert_eq!(rested, Rested::Woken);
    assert!(
        took < std::time::Duration::from_millis(100),
        "waited {took:?} with a wake already in hand; the ceiling is \
         {LONGEST_BACKOFF:?} and that is what used to be paid"
    );
}

/// And one that arrives during the wait still cuts it short.
#[test]
fn a_wake_during_the_wait_cuts_it_short() {
    let halt = std::sync::Arc::new(Halt::default());
    let began = halt.generation();

    let waker = std::sync::Arc::clone(&halt);
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(50));
        waker.nudge();
    });

    let started = std::time::Instant::now();
    assert_eq!(halt.rest(LONGEST_BACKOFF, began), Rested::Woken);
    assert!(started.elapsed() < std::time::Duration::from_secs(1));
}

/// Without a nudge the wait is the wait, or the climb would never happen.
#[test]
fn an_undisturbed_wait_runs_its_course() {
    let halt = Halt::default();
    let began = halt.generation();

    let started = std::time::Instant::now();
    let rested = halt.rest(std::time::Duration::from_millis(200), began);
    let took = started.elapsed();

    assert_eq!(rested, Rested::Elapsed);
    assert!(
        took >= std::time::Duration::from_millis(150),
        "returned after {took:?}; a wait nothing interrupted came back early"
    );
}

/// Disposal outranks a wake, whichever order they arrive in: a nudged
/// endpoint that is then freed must not come back.
#[test]
fn stopping_outranks_a_pending_wake() {
    let halt = Halt::default();
    let began = halt.generation();

    halt.nudge();
    halt.stop();

    assert_eq!(halt.rest(LONGEST_BACKOFF, began), Rested::Stopped);
    let (near, far) = socket_pair();
    assert!(
        !halt.arm(halt.generation(), crate::endpoint::Interrupt::Local(near)),
        "a stopped endpoint armed another transport"
    );
    drop(far);
}

/// Four wakes in a row are four reconnects, not one. A laptop opened four
/// times is the ordinary case, and a generation that stopped moving — or a
/// flag that stopped being noticed — would leave it offline.
#[test]
fn every_wake_counts_not_just_the_first() {
    let halt = Halt::default();
    let mut began = halt.generation();

    for round in 1..=4 {
        halt.nudge();
        assert_eq!(
            halt.rest(LONGEST_BACKOFF, began),
            Rested::Woken,
            "wake {round} was not acted on"
        );
        began = halt.generation();
        assert_eq!(began, round, "the generation stopped moving at {began}");
    }

    // And with no wake pending, the next wait is an ordinary one.
    assert_eq!(
        halt.rest(std::time::Duration::from_millis(50), began),
        Rested::Elapsed
    );
}
