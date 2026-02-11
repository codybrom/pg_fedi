use pgrx::prelude::*;

/// Retry backoff schedule in seconds: 1m, 5m, 30m, 2h, 12h, 24h, 3d, 7d
const RETRY_INTERVALS: &[i64] = &[60, 300, 1800, 7200, 43200, 86400, 259200, 604800];

/// Get pending deliveries for the external worker.
/// Returns rows with all info needed to perform the HTTP POST.
#[pg_extern]
fn ap_get_pending_deliveries(
    batch_size: i32,
) -> TableIterator<
    'static,
    (
        name!(delivery_id, i64),
        name!(inbox_uri, String),
        name!(activity_json, pgrx::JsonB),
        name!(actor_uri, String),
        name!(key_id, String),
        name!(private_key_pem, String),
    ),
> {
    let rows: Vec<_> = Spi::connect(|client| {
        let mut results = Vec::new();
        let tup_table = client
            .select(
                "SELECT d.id, d.inbox_uri, act.raw, a.uri, k.key_id, k.private_key_pem
                 FROM ap_deliveries d
                 JOIN ap_activities act ON act.id = d.activity_id
                 JOIN ap_actors a ON a.id = act.actor_id
                 JOIN ap_keys k ON k.actor_id = a.id
                 WHERE (d.status = 'Queued' OR d.status = 'Failed')
                   AND d.next_retry_at <= now()
                   AND k.private_key_pem IS NOT NULL
                 ORDER BY d.next_retry_at
                 LIMIT $1",
                None,
                &[batch_size.into()],
            )
            .expect("failed to query deliveries");

        for row in tup_table {
            let delivery_id: i64 = row
                .get_datum_by_ordinal(1)
                .unwrap()
                .value()
                .unwrap()
                .unwrap();
            let inbox_uri: String = row
                .get_datum_by_ordinal(2)
                .unwrap()
                .value()
                .unwrap()
                .unwrap();
            let activity_json: pgrx::JsonB = row
                .get_datum_by_ordinal(3)
                .unwrap()
                .value()
                .unwrap()
                .unwrap();
            let actor_uri: String = row
                .get_datum_by_ordinal(4)
                .unwrap()
                .value()
                .unwrap()
                .unwrap();
            let key_id: String = row
                .get_datum_by_ordinal(5)
                .unwrap()
                .value()
                .unwrap()
                .unwrap();
            let private_key_pem: String = row
                .get_datum_by_ordinal(6)
                .unwrap()
                .value()
                .unwrap()
                .unwrap();

            results.push((
                delivery_id,
                inbox_uri,
                activity_json,
                actor_uri,
                key_id,
                private_key_pem,
            ));
        }

        results
    });

    TableIterator::new(rows)
}

/// Mark a delivery as successfully delivered.
#[pg_extern]
fn ap_delivery_success(delivery_id: i64, status_code: i32) {
    Spi::run_with_args(
        "UPDATE ap_deliveries SET
            status = 'Delivered',
            attempts = attempts + 1,
            last_attempt_at = now(),
            last_status_code = $2
         WHERE id = $1",
        &[delivery_id.into(), status_code.into()],
    )
    .expect("failed to mark delivery success");
}

/// Mark a delivery as failed, scheduling retry with exponential backoff.
/// If max attempts reached, marks as Expired.
#[pg_extern]
fn ap_delivery_failure(delivery_id: i64, error_message: &str, status_code: Option<i32>) {
    let max_attempts = crate::guc::MAX_DELIVERY_ATTEMPTS.get();

    // Get current attempt count
    let current_attempts = Spi::get_one_with_args::<i32>(
        "SELECT attempts FROM ap_deliveries WHERE id = $1",
        &[delivery_id.into()],
    )
    .unwrap()
    .unwrap_or(0);

    let new_attempts = current_attempts + 1;

    if new_attempts >= max_attempts {
        // Expired
        Spi::run_with_args(
            "UPDATE ap_deliveries SET
                status = 'Expired',
                attempts = $2,
                last_attempt_at = now(),
                last_error = $3,
                last_status_code = $4
             WHERE id = $1",
            &[
                delivery_id.into(),
                new_attempts.into(),
                error_message.into(),
                status_code.into(),
            ],
        )
        .expect("failed to mark delivery expired");
    } else {
        // Schedule retry
        let interval_idx = (new_attempts as usize).min(RETRY_INTERVALS.len() - 1);
        let interval_secs = RETRY_INTERVALS[interval_idx];

        Spi::run_with_args(
            "UPDATE ap_deliveries SET
                status = 'Failed',
                attempts = $2,
                last_attempt_at = now(),
                next_retry_at = now() + ($3 || ' seconds')::interval,
                last_error = $4,
                last_status_code = $5
             WHERE id = $1",
            &[
                delivery_id.into(),
                new_attempts.into(),
                interval_secs.to_string().into(),
                error_message.into(),
                status_code.into(),
            ],
        )
        .expect("failed to schedule delivery retry");
    }
}

/// Get delivery queue statistics.
#[pg_extern]
fn ap_delivery_stats() -> TableIterator<'static, (name!(status, String), name!(count, i64))> {
    let rows: Vec<_> = Spi::connect(|client| {
        let mut results = Vec::new();
        let tup_table = client
            .select(
                "SELECT status::text, count(*)
                 FROM ap_deliveries
                 GROUP BY status
                 ORDER BY status",
                None,
                &[],
            )
            .expect("failed to query delivery stats");

        for row in tup_table {
            let status: String = row
                .get_datum_by_ordinal(1)
                .unwrap()
                .value()
                .unwrap()
                .unwrap();
            let count: i64 = row
                .get_datum_by_ordinal(2)
                .unwrap()
                .value()
                .unwrap()
                .unwrap();
            results.push((status, count));
        }

        results
    });

    TableIterator::new(rows)
}
