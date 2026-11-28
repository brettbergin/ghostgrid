// ghostgrid-sessiond: owns every ghostgrid pane's shell (each in its own
// ConPTY) so the shells keep running when the app quits. ghostgrid starts it
// on demand, detached from itself, one per user and logon session and
// protocol version, and talks to it over a named pipe, one connection per
// pane (see ghostgrid_core::protocol). It exits on its own once it has had
// no shells and no connections for 30 seconds.
//
// Usage: ghostgrid-sessiond --pipe <name> [--log <path>]
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

#[cfg(not(windows))]
fn main() {
    eprintln!("ghostgrid-sessiond runs on Windows only");
    std::process::exit(64);
}

#[cfg(windows)]
fn main() {
    server::main();
}

#[cfg(windows)]
mod server {
    use std::collections::HashMap;
    use std::fs::OpenOptions;
    use std::io::{Read, Write};
    use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
    use std::sync::{Arc, Mutex, OnceLock};
    use std::time::{Duration, Instant};

    use ghostgrid_core::history::OutputHistory;
    use ghostgrid_core::protocol::{FrameDecoder, SessionLaunch, SessionMessage, PROTOCOL_VERSION};
    use ghostgrid_core::quit_sender::QuitSender;
    use ghostgrid_sessiond::pipe;
    use portable_pty::{native_pty_system, ChildKiller, CommandBuilder, MasterPty, PtySize};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::windows::named_pipe::NamedPipeServer;
    use tokio::sync::mpsc;

    static LOG: OnceLock<Mutex<Option<std::fs::File>>> = OnceLock::new();

    pub fn log(message: &str) {
        let line = format!("{} sessiond: {message}\n", ghostgrid_sessiond::timestamp());
        if let Some(lock) = LOG.get() {
            if let Some(file) = lock.lock().unwrap().as_mut() {
                let _ = file.write_all(line.as_bytes());
                return;
            }
        }
        eprint!("{line}");
    }

    type Outbox = mpsc::Sender<SessionMessage>;
    /// Ends a connection's reader (a newer pane took its shell over).
    type Closer = Arc<tokio::sync::Notify>;

    /// One shell and its ConPTY.
    struct Session {
        id: String,
        pid: Option<u32>,
        history: Mutex<OutputHistory>,
        /// The pane attached to it: connection number and its outbox.
        client: Mutex<Option<(u64, Outbox, Closer)>>,
        writer: Mutex<Box<dyn Write + Send>>,
        master: Mutex<Option<Box<dyn MasterPty + Send>>>,
        killer: Mutex<Box<dyn ChildKiller + Send + Sync>>,
        size: Mutex<PtySize>,
        /// Set on attach: the next resize makes the console's programs
        /// redraw for the new pane even when the size did not change.
        redraw_on_resize: AtomicBool,
    }

    impl Session {
        fn attach(&self, connection: u64, outbox: Outbox, closer: Closer) {
            let old = self.client.lock().unwrap().replace((connection, outbox.clone(), closer));
            if let Some((old_id, old_outbox, old_closer)) = old {
                if old_id != connection {
                    // A newer pane took this shell over: tell the stale one
                    // and end its connection.
                    let _ = old_outbox.try_send(SessionMessage::Failure("attached elsewhere".into()));
                    old_closer.notify_one();
                }
            }
            let replay = self.history.lock().unwrap().replay();
            let _ = outbox.try_send(SessionMessage::Attached { id: self.id.clone(), replay });
            self.redraw_on_resize.store(true, Ordering::SeqCst);
        }

        fn detach(&self, connection: u64) {
            let mut client = self.client.lock().unwrap();
            if client.as_ref().is_some_and(|(id, _, _)| *id == connection) {
                *client = None;
            }
        }

        fn output(&self, data: Vec<u8>) {
            self.history.lock().unwrap().append(&data);
            let outbox = self.client.lock().unwrap().as_ref().map(|(_, o, _)| o.clone());
            if let Some(outbox) = outbox {
                // Blocks the reader thread while the pane is slow to read,
                // rather than dropping output.
                let _ = outbox.blocking_send(SessionMessage::Output(data));
            }
        }

        fn input(&self, data: &[u8]) {
            let mut writer = self.writer.lock().unwrap();
            let _ = writer.write_all(data).and_then(|_| writer.flush());
        }

        fn resize(&self, columns: u16, rows: u16, width: u16, height: u16) {
            let size = PtySize { rows: rows.max(1), cols: columns.max(1), pixel_width: width, pixel_height: height };
            let master = self.master.lock().unwrap();
            let Some(master) = master.as_ref() else { return };
            let unchanged = {
                let current = self.size.lock().unwrap();
                current.rows == size.rows && current.cols == size.cols
            };
            if self.redraw_on_resize.swap(false, Ordering::SeqCst) && unchanged {
                // Console programs only hear about size changes: step one
                // row taller and back so full-screen apps repaint.
                let _ = master.resize(PtySize { rows: size.rows + 1, ..size });
            }
            let _ = master.resize(size);
            *self.size.lock().unwrap() = size;
        }

        fn terminate(&self) {
            let _ = self.killer.lock().unwrap().kill();
        }
    }

    #[derive(Default)]
    struct State {
        sessions: HashMap<String, Arc<Session>>,
        connections: usize,
    }

    struct Server {
        state: Mutex<State>,
        next_connection: AtomicU64,
    }

    impl Server {
        fn spawn(self: &Arc<Self>, launch: &SessionLaunch) -> Result<Arc<Session>, String> {
            let size = PtySize { rows: launch.rows.max(1), cols: launch.columns.max(1), pixel_width: 0, pixel_height: 0 };
            let pair = native_pty_system().openpty(size).map_err(|e| format!("openpty: {e}"))?;
            let mut command = CommandBuilder::new(&launch.executable);
            if launch.arguments.len() > 1 {
                command.args(&launch.arguments[1..]);
            }
            command.env_clear();
            for (key, value) in &launch.environment {
                command.env(key, value);
            }
            if let Some(directory) = launch.working_directory.as_deref().filter(|d| std::path::Path::new(d).is_dir()) {
                command.cwd(directory);
            }
            let mut child = pair.slave.spawn_command(command).map_err(|e| format!("could not start {}: {e}", launch.executable))?;
            drop(pair.slave);
            let reader = pair.master.try_clone_reader().map_err(|e| format!("reader: {e}"))?;
            let writer = pair.master.take_writer().map_err(|e| format!("writer: {e}"))?;
            let session = Arc::new(Session {
                id: launch.id.clone(),
                pid: child.process_id(),
                history: Mutex::new(OutputHistory::new()),
                client: Mutex::new(None),
                writer: Mutex::new(writer),
                master: Mutex::new(Some(pair.master)),
                killer: Mutex::new(child.clone_killer()),
                size: Mutex::new(size),
                redraw_on_resize: AtomicBool::new(false),
            });
            log(&format!("started {} pid {}: {}", launch.id, session.pid.unwrap_or(0), launch.executable));

            let reading = session.clone();
            std::thread::Builder::new()
                .name(format!("pty-read-{}", launch.id))
                .spawn(move || read_pty(reader, reading))
                .map_err(|e| e.to_string())?;

            let server = self.clone();
            let waiting = session.clone();
            std::thread::Builder::new()
                .name(format!("pty-wait-{}", launch.id))
                .spawn(move || {
                    let code = child.wait().map(|s| s.exit_code() as i32).unwrap_or(-1);
                    // Let the last output drain before the pane hears it ended.
                    std::thread::sleep(Duration::from_millis(200));
                    server.reap(&waiting, code);
                })
                .map_err(|e| e.to_string())?;
            Ok(session)
        }

        fn reap(&self, session: &Arc<Session>, code: i32) {
            {
                let mut state = self.state.lock().unwrap();
                if !state.sessions.get(&session.id).is_some_and(|s| Arc::ptr_eq(s, session)) {
                    return;
                }
                state.sessions.remove(&session.id);
            }
            // Closing the pseudoconsole ends its reader and any program
            // still attached to it.
            session.master.lock().unwrap().take();
            if let Some((_, outbox, _)) = session.client.lock().unwrap().take() {
                let _ = outbox.blocking_send(SessionMessage::Exited { code });
            }
            log(&format!("ended {} code {code}", session.id));
        }

        fn idle(&self) -> bool {
            let state = self.state.lock().unwrap();
            state.sessions.is_empty() && state.connections == 0
        }
    }

    fn read_pty(mut reader: Box<dyn Read + Send>, session: Arc<Session>) {
        let mut buffer = vec![0u8; 64 * 1024];
        loop {
            match reader.read(&mut buffer) {
                Ok(0) | Err(_) => return,
                Ok(n) => session.output(buffer[..n].to_vec()),
            }
        }
    }

    async fn serve(server: Arc<Server>, mut pipe: NamedPipeServer) {
        let connection = server.next_connection.fetch_add(1, Ordering::SeqCst);
        let peer = pipe::client_pid(&pipe);
        server.state.lock().unwrap().connections += 1;
        let (outbox, mut inbox) = mpsc::channel::<SessionMessage>(256);
        let closer: Closer = Arc::new(tokio::sync::Notify::new());
        let (mut read_half, mut write_half) = tokio::io::split(&mut pipe);
        // The writer runs until every sender is gone: the reader's (dropped
        // when the client goes or breaks the protocol) and the session's
        // (dropped on detach, or when another pane takes the shell over), so
        // a last Failure is still delivered. A Failure alone does not end
        // the connection: after "no such session" the pane sends Create.
        let writer = async move {
            while let Some(message) = inbox.recv().await {
                if write_half.write_all(&message.encode()).await.is_err() {
                    break;
                }
            }
        };
        let reader_server = server.clone();
        let reader = async move {
            let server = reader_server;
            let mut decoder = FrameDecoder::new();
            let mut greeted = false;
            let mut session: Option<Arc<Session>> = None;
            let mut buffer = vec![0u8; 64 * 1024];
            'read: loop {
                let n = tokio::select! {
                    read = read_half.read(&mut buffer) => match read {
                        Ok(0) | Err(_) => break,
                        Ok(n) => n,
                    },
                    _ = closer.notified() => break,
                };
                for message in decoder.push(&buffer[..n]) {
                    if !greeted {
                        if message == (SessionMessage::Hello { version: PROTOCOL_VERSION }) {
                            greeted = true;
                            let _ = outbox.send(SessionMessage::Welcome { version: PROTOCOL_VERSION }).await;
                            continue;
                        }
                        if matches!(message, SessionMessage::Hello { .. }) {
                            let _ = outbox.send(SessionMessage::Failure("protocol version mismatch".into())).await;
                        }
                        break 'read;
                    }
                    match message {
                        SessionMessage::Create(launch) => {
                            let existing = server.state.lock().unwrap().sessions.get(&launch.id).cloned();
                            let target = match existing {
                                Some(existing) => Ok(existing),
                                None => server.spawn(&launch).inspect(|s| {
                                    server.state.lock().unwrap().sessions.insert(launch.id.clone(), s.clone());
                                }),
                            };
                            match target {
                                Ok(target) => {
                                    target.attach(connection, outbox.clone(), closer.clone());
                                    session = Some(target);
                                }
                                Err(error) => {
                                    log(&error);
                                    let _ = outbox.send(SessionMessage::Failure(error)).await;
                                }
                            }
                        }
                        SessionMessage::Attach { id } => {
                            let found = server.state.lock().unwrap().sessions.get(&id).cloned();
                            match found {
                                Some(target) => {
                                    target.attach(connection, outbox.clone(), closer.clone());
                                    session = Some(target);
                                }
                                None => {
                                    let _ = outbox.send(SessionMessage::Failure("no such session".into())).await;
                                }
                            }
                        }
                        SessionMessage::Input(data) => {
                            if let Some(s) = &session {
                                s.input(&data);
                            }
                        }
                        SessionMessage::Resize { columns, rows, width, height } => {
                            if let Some(s) = &session {
                                s.resize(columns, rows, width, height);
                            }
                        }
                        SessionMessage::Terminate => {
                            if let Some(s) = &session {
                                // Say who ended a shell: a quiet end would look like lost work.
                                let sender = describe_sender(peer);
                                log(&format!("terminate {} {sender}", s.id));
                                s.terminate();
                            }
                        }
                        _ => {}
                    }
                }
                if decoder.is_broken() {
                    break;
                }
            }
            if let Some(s) = session {
                s.detach(connection);
            }
        };
        tokio::join!(writer, reader);
        server.state.lock().unwrap().connections -= 1;
    }

    fn describe_sender(pid: Option<u32>) -> String {
        let path = pid.and_then(pipe::process_path);
        let parent = path.as_ref().and(pid).and_then(pipe::parent_pid);
        QuitSender {
            pid,
            path,
            parent_pid: parent,
            parent_path: parent.and_then(pipe::process_path),
        }
        .to_string()
    }

    pub fn main() {
        let args: Vec<String> = std::env::args().collect();
        let value = |flag: &str| args.iter().position(|a| a == flag).and_then(|i| args.get(i + 1)).cloned();
        let name = value("--pipe").or_else(|| pipe::pipe_name().ok());
        let Some(name) = name else {
            eprintln!("usage: ghostgrid-sessiond --pipe <name> [--log <path>]");
            std::process::exit(64);
        };
        let file = value("--log").and_then(|path| OpenOptions::new().create(true).append(true).open(path).ok());
        let _ = LOG.set(Mutex::new(file));

        let runtime = tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().expect("tokio runtime");
        runtime.block_on(async move {
            let security = match pipe::UserOnly::new() {
                Ok(s) => s,
                Err(e) => {
                    log(&format!("security descriptor: {e}"));
                    std::process::exit(1);
                }
            };
            let mut listener = match pipe::create_server(&name, &security, true) {
                Ok(l) => l,
                Err(e) => {
                    // Another helper already serves this pipe: it owns the shells.
                    log(&format!("not starting, {name} is taken: {e}"));
                    std::process::exit(0);
                }
            };
            log(&format!("listening on {name} (pid {})", std::process::id()));
            let server = Arc::new(Server { state: Mutex::new(State::default()), next_connection: AtomicU64::new(1) });

            let idle_server = server.clone();
            tokio::spawn(async move {
                let mut idle_since: Option<Instant> = Some(Instant::now());
                loop {
                    tokio::time::sleep(Duration::from_secs(10)).await;
                    if !idle_server.idle() {
                        idle_since = None;
                        continue;
                    }
                    let since = *idle_since.get_or_insert_with(Instant::now);
                    if since.elapsed() >= Duration::from_secs(30) {
                        log("idle: exiting");
                        std::process::exit(0);
                    }
                }
            });

            loop {
                if let Err(e) = listener.connect().await {
                    log(&format!("connect: {e}"));
                    tokio::time::sleep(Duration::from_millis(50)).await;
                    continue;
                }
                let connected = listener;
                listener = match pipe::create_server(&name, &security, false) {
                    Ok(l) => l,
                    Err(e) => {
                        log(&format!("create pipe instance: {e}"));
                        std::process::exit(1);
                    }
                };
                tokio::spawn(serve(server.clone(), connected));
            }
        });
    }
}
