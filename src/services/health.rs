use std::{sync::{Arc, atomic::{AtomicBool, Ordering}}, time::Duration};


use crate::repositories::LinkRepository;

#[derive(Clone,Default)]
pub struct Readiness(Arc<AtomicBool>);

impl Readiness {
    pub fn start_draining(&self) {
        self.0.store(true,Ordering::Release);
    }
    pub fn is_draining(&self) -> bool {
        self.0.load(Ordering::Acquire)
    }
}

#[derive(Debug,Clone,Copy,PartialEq,Eq)]
pub enum ReadinessStatus {
    Ready,
    Draining,
    DatabaseUnavailable
}

pub struct HealthService {
    links:Arc<dyn LinkRepository>,
    readiness:Readiness,
    check_timeout:Duration
}

impl HealthService {
    pub fn new(links:Arc<dyn LinkRepository>, readiness:Readiness,check_timeout:Duration) -> Self {
        Self {
            links,readiness,check_timeout
        }
    }
    pub fn readiness_handle(&self) -> Readiness {
        self.readiness.clone()
    }
    pub async fn readiness(&self) -> ReadinessStatus {
        if self.readiness.is_draining() {
            return ReadinessStatus::Draining;
        }
        //Bounded: a hung database must make the probe fail not hang
        match tokio::time::timeout(self.check_timeout,self.links.ping()).await {
            Ok(Ok(())) => ReadinessStatus::Ready,
            _=> ReadinessStatus::DatabaseUnavailable
        }
    }
}