mod collab;
mod core;
mod git;
mod repos;

fn main() {
    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .max_blocking_threads(128)
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => {
            eprintln!("Unable to start runtime: {error}");
            std::process::exit(1);
        }
    };
    let result = runtime.block_on(core::serve());
    git::shutdown();
    runtime.shutdown_timeout(std::time::Duration::from_secs(15));
    if let Err(error) = result {
        eprintln!("GitClub startup/server error: {}", error.message);
        std::process::exit(1);
    }
}
