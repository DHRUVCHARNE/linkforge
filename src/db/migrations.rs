use sqlx::postgres::PgPool;

//Runs at boot. migrate embeds the SQL at compile time so the binary
//is self contained - no migrations /directory needed at runtime

pub async fn run(pool: &PgPool) -> anyhow::Result<()> {
    sqlx::migrate!("./migrations").run(pool).await?;
    Ok(())
}
