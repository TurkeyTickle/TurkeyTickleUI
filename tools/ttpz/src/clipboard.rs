use std::io::Write;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

const COMMANDS: &[&[&str]] = &[
    &["wl-copy"],
    &["xclip", "-selection", "clipboard"],
    &["xsel", "-b", "-i"],
    &["pbcopy"],
    &["clip.exe"],
];

pub fn try_copy(text: &str) -> bool {
    if COMMANDS.iter().any(|command| try_run(command, Some(text))) {
        return true;
    }
    cfg!(target_os = "linux")
        && try_run(
            &["qdbus6", "org.kde.klipper", "/klipper", "org.kde.klipper.klipper.setClipboardContents", text],
            None,
        )
}

fn try_run(command: &[&str], input: Option<&str>) -> bool {
    let mut child = match Command::new(command[0])
        .args(&command[1..])
        .stdin(if input.is_some() { Stdio::piped() } else { Stdio::null() })
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(child) => child,
        Err(_) => return false,
    };
    if let (Some(input), Some(mut stdin)) = (input, child.stdin.take())
        && stdin.write_all(input.as_bytes()).is_err()
    {
        let _ = child.kill();
        return false;
    }

    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return status.success(),
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(20)),
            _ => {
                let _ = child.kill();
                return false;
            }
        }
    }
}
