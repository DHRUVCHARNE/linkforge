// Backpressure Policy: Drop on Full.
// The Channel is bounded. When the writer cannot keep up, `try_send` fails
// and the click is discarded rather than awaited.
//Why drop rather than block:
// * Blocking would push DB latency back onto the redirect path - the exact coupling this phase exists to remove a slow database would make redirects slow, which is a correctness of service failure.
// * Analytics are best-effort. An undercounted click is acceptable; a delayed redirect is not
// * A Bounded + drop gives a HARD memory ceiling. Unbounded would trade a latency problem for an OOM (Out Of Memory)
// The cost: under sustained overload, click counts undercount. Dropped events are counted and logged so the loss is VISIBLE rather than silent.
use crate::{config::AnalyticsConfig, domain::click::Click, repositories::ClickRepository};
use std::{
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};
use tokio::{sync::mpsc, task::JoinHandle};

#[derive(Default)]
pub struct WriterStats {
    pub enqueued: AtomicU64,
    pub dropped: AtomicU64,
    pub batches: AtomicU64,
    pub rows_written: AtomicU64,
    pub failed_batches: AtomicU64,
}
#[derive(Clone)]
pub struct ClickSender {
    tx: mpsc::Sender<Click>,
    stats: Arc<WriterStats>,
    max_batch: usize,
}

impl ClickSender {
    /// Non-blocking. Never awaits - this is called from the redirect path
    pub fn record(&self, click: Click) {
        match self.tx.try_send(click) {
            Ok(()) => {
                self.stats.enqueued.fetch_add(1, Ordering::Relaxed);
                metrics::counter!("linkforge_clicks_enqueued_total").increment(1);
            }
            Err(_) => {
                let n = self.stats.dropped.fetch_add(1, Ordering::Relaxed) + 1;
                metrics::counter!("linkforge_clicks_dropped_total").increment(1);

                if n % 1000 == 1 {
                    tracing::warn!(dropped_total = n, "click_channel full, dropping");
                }
            }
        }
        metrics::gauge!("linkforge_click_queue_depth").set(self.queue_depth() as f64);
    }
    pub fn queue_depth(&self) -> usize {
        self.tx.max_capacity() - self.tx.capacity()
    }
    pub fn stats(&self) -> &WriterStats {
        &self.stats
    }
    pub fn max_batch(&self) -> usize {
        self.max_batch
    }
}

pub fn spawn(
    repo: Arc<dyn ClickRepository>,
    cfg: &AnalyticsConfig,
) -> (ClickSender, JoinHandle<()>) {
    let (tx, mut rx) = mpsc::channel::<Click>(cfg.channel_capacity);
    let stats = Arc::new(WriterStats::default());
    let max_batch = cfg.max_batch;
    let max_wait = Duration::from_millis(cfg.batch_wait_ms);
    let task_stats = stats.clone();

    let handle = tokio::spawn(async move {
        let mut batch: Vec<Click> = Vec::with_capacity(max_batch);
        while let Some(first) = rx.recv().await {
            //clears previous clicks in the batch
            batch.clear();
            batch.push(first);
            //Drain whatever is already queued, upto MAX_BATCH size without
            //awaiting - try_recv returns immediately when empty.
            while batch.len() < max_batch {
                match rx.try_recv() {
                    Ok(c) => batch.push(c),
                    Err(_) => break,
                }
            }
            //If batch is small wait briefly for more. Trade a few ms of staleness for far fewer DB round trips.
            if batch.len() < max_batch {
                let deadline = tokio::time::sleep(max_wait);
                tokio::pin!(deadline);
                loop {
                    tokio::select! {
                        maybe = rx.recv()=> match maybe {
                            Some(c) => {
                                batch.push(c);
                                if batch.len()>=max_batch {break;}
                            },
                            None=> break,
                            //Channel closed
                        },
                        _= &mut deadline => break,
                    }
                }
            }
            match repo.insert_batch(&batch).await {
                Ok(()) => {
                    task_stats.batches.fetch_add(1, Ordering::Relaxed);
                    metrics::counter!("linkforge_click_batches_total").increment(1);

                    task_stats.rows_written.fetch_add(batch.len() as u64, Ordering::Relaxed);
                    metrics::counter!("linkforge_click_rrows_written_total")
                        .increment(batch.len() as u64);
                }
                Err(e) => {
                    task_stats.failed_batches.fetch_add(1, Ordering::Relaxed);
                    metrics::counter!("linkforge_click_batch_failures_total").increment(1);

                    tracing::error!(error=?e,n=batch.len(),"click batch insert failed");
                }
            }
        }
        tracing::info!(
            rows_writtem = task_stats.rows_written.load(Ordering::Relaxed),
            dropped = task_stats.dropped.load(Ordering::Relaxed),
            "click writer drained and stopped"
        );
    });
    (ClickSender { tx, stats, max_batch }, handle)
}
