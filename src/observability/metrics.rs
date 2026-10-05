use metrics_exporter_prometheus::{PrometheusBuilder, PrometheusHandle};

pub fn init() -> anyhow::Result<PrometheusHandle> {
    let handle = PrometheusBuilder::new().install_recorder()?;
    Ok(handle)
}
