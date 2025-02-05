//! This module communicates with Pyth Benchmarks, an API for historical price feeds and their updates.

use {
    crate::aggregate::{
        PriceFeedUpdate,
        PriceFeedsWithUpdateData,
        UnixTimestamp,
    },
    anyhow::Result,
    base64::{
        engine::general_purpose::STANDARD as base64_standard_engine,
        Engine as _,
    },
    pyth_sdk::{
        PriceFeed,
        PriceIdentifier,
    },
};

const BENCHMARKS_REQUEST_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

#[derive(serde::Deserialize, Debug, Clone)]
enum BlobEncoding {
    #[serde(rename = "base64")]
    Base64,
    #[serde(rename = "hex")]
    Hex,
}

#[derive(serde::Deserialize, Debug, Clone)]
struct BinaryBlob {
    pub encoding: BlobEncoding,
    pub data:     Vec<String>,
}

#[derive(serde::Deserialize, Debug, Clone)]
struct BenchmarkUpdates {
    pub parsed: Vec<PriceFeed>,
    pub binary: BinaryBlob,
}

impl TryFrom<BinaryBlob> for Vec<Vec<u8>> {
    type Error = anyhow::Error;

    fn try_from(binary_blob: BinaryBlob) -> Result<Self> {
        binary_blob
            .data
            .iter()
            .map(|datum| {
                Ok(match binary_blob.encoding {
                    BlobEncoding::Base64 => base64_standard_engine.decode(datum)?,
                    BlobEncoding::Hex => hex::decode(datum)?,
                })
            })
            .collect::<Result<_>>()
    }
}

impl TryFrom<BenchmarkUpdates> for PriceFeedsWithUpdateData {
    type Error = anyhow::Error;
    fn try_from(benchmark_updates: BenchmarkUpdates) -> Result<Self> {
        Ok(PriceFeedsWithUpdateData {
            price_feeds: benchmark_updates
                .parsed
                .into_iter()
                .map(|price_feed| PriceFeedUpdate {
                    price_feed,
                    slot: None,
                    received_at: None,
                    update_data: None,
                    prev_publish_time: None, // TODO: Set this field when Benchmarks API supports it.
                })
                .collect::<Vec<_>>(),
            update_data: benchmark_updates.binary.try_into()?,
        })
    }
}

#[async_trait::async_trait]
pub trait Benchmarks {
    async fn get_verified_price_feeds(
        &self,
        price_ids: Vec<PriceIdentifier>,
        publish_time: UnixTimestamp,
    ) -> Result<PriceFeedsWithUpdateData>;
}

#[async_trait::async_trait]
impl Benchmarks for crate::state::State {
    async fn get_verified_price_feeds(
        &self,
        price_ids: Vec<PriceIdentifier>,
        publish_time: UnixTimestamp,
    ) -> Result<PriceFeedsWithUpdateData> {
        let endpoint = self
            .benchmarks_endpoint
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("Benchmarks endpoint is not set"))?
            .join(&format!("/v1/updates/price/{}", publish_time))
            .unwrap();

        let client = reqwest::Client::new();
        let mut request = client
            .get(endpoint)
            .timeout(BENCHMARKS_REQUEST_TIMEOUT)
            .query(&[("encoding", "hex")])
            .query(&[("parsed", "true")]);

        for price_id in price_ids {
            request = request.query(&[("ids", price_id)])
        }

        let response = request.send().await?;

        let benchmark_updates: BenchmarkUpdates = response.json().await?;
        benchmark_updates.try_into()
    }
}
