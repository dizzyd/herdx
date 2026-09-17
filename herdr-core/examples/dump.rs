//! Dumps the current pane surface as text, to check what the server sends.

use herdr_core::client::{default_socket_path, hello, EndpointConnection};
use herdr_core::protocol::ServerMessage;

fn main() -> std::io::Result<()> {
    let mut conn = EndpointConnection::connect(&default_socket_path(), &hello(100, 20, 8, 17))?;
    for _ in 0..80 {
        if let ServerMessage::PaneSurface(f) = conn.recv()? {
            let w = f.frame.width as usize;
            let non_blank = f
                .frame
                .cells
                .iter()
                .filter(|c| !c.symbol.trim().is_empty())
                .count();
            let empty_symbol = f.frame.cells.iter().filter(|c| c.symbol.is_empty()).count();
            println!(
                "{}x{}, {} cells: {} non-blank, {} empty-symbol",
                f.frame.width,
                f.frame.height,
                f.frame.cells.len(),
                non_blank,
                empty_symbol
            );
            for row in 0..f.frame.height.min(8) as usize {
                let line: String = f.frame.cells[row * w..(row + 1) * w]
                    .iter()
                    .map(|c| {
                        if c.symbol.is_empty() {
                            '_'
                        } else {
                            c.symbol.chars().next().unwrap()
                        }
                    })
                    .collect();
                println!("{row:2} |{line}|");
            }
            let sample = &f.frame.cells[0];
            println!("cell[0]: fg={:#010x} bg={:#010x} mod={:#06x}", sample.fg, sample.bg, sample.modifier);
            return Ok(());
        }
    }
    Ok(())
}
