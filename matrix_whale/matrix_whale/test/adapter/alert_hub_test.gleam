import adapter/alert_hub
import gleeunit/should

pub fn needs_resync_no_gap_test() {
  // exactly before oldest event in ring: client needs replay of full ring
  alert_hub.needs_resync(9, 10, 20) |> should.equal(False)
  // middle of ring: client needs replay of events 16..19
  alert_hub.needs_resync(15, 10, 20) |> should.equal(False)
  // at the head of the ring: client is up to date, 0 events to replay
  alert_hub.needs_resync(19, 10, 20) |> should.equal(False)
}

pub fn needs_resync_gap_test() {
  // client is behind the ring buffer: cannot replay missing events
  alert_hub.needs_resync(8, 10, 20) |> should.equal(True)
  alert_hub.needs_resync(0, 10, 20) |> should.equal(True)
  alert_hub.needs_resync(-5, 10, 20) |> should.equal(True)
}

pub fn needs_resync_restart_test() {
  let prev_boot = 1_000_000
  let next_boot = 2_000_000
  // Client holds an id from before server restart: must resync even if new
  // server has already emitted 20 events
  let client_from_prev_run = prev_boot + 5
  alert_hub.needs_resync(client_from_prev_run, next_boot, next_boot + 20)
  |> should.equal(True)

  // Current client with an id from this run must not resync
  let current_client = next_boot + 5
  alert_hub.needs_resync(current_client, next_boot, next_boot + 20)
  |> should.equal(False)

  // Client ahead of known events must resync
  alert_hub.needs_resync(next_boot + 50, next_boot, next_boot + 20)
  |> should.equal(True)
}

pub fn needs_resync_empty_ring_test() {
  let boot_ms = 1_700_000_000_000
  // empty ring: oldest = boot_ms, next_event_id = boot_ms
  // since == boot_ms - 1 means no gap, fresh start
  alert_hub.needs_resync(boot_ms - 1, boot_ms, boot_ms) |> should.equal(False)
  // client with id from before restart must resync
  alert_hub.needs_resync(5, boot_ms, boot_ms) |> should.equal(True)
  alert_hub.needs_resync(boot_ms - 2, boot_ms, boot_ms) |> should.equal(True)
  // since > boot_ms - 1 is ahead of empty ring
  alert_hub.needs_resync(boot_ms, boot_ms, boot_ms) |> should.equal(True)
}
