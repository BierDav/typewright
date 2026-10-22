// WASI has no mmap (nor dup): a read-only "map" is a heap copy of the file range; writable file maps are unsupported.
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};

pub struct MmapInner {
    buf: Vec<u8>,
}

fn read_range(len: usize, mut file: &File, offset: u64) -> io::Result<MmapInner> {
    file.seek(SeekFrom::Start(offset))?;
    let mut buf = vec![0; len];
    file.read_exact(&mut buf)?;
    Ok(MmapInner { buf })
}

impl MmapInner {
    pub fn map(len: usize, file: &File, offset: u64, _: bool, _: bool, _: bool) -> io::Result<MmapInner> {
        read_range(len, file, offset)
    }

    pub fn map_exec(len: usize, file: &File, offset: u64, _: bool, _: bool, _: bool) -> io::Result<MmapInner> {
        read_range(len, file, offset)
    }

    pub fn map_mut(_: usize, _: &File, _: u64, _: bool, _: bool, _: bool) -> io::Result<MmapInner> {
        Err(io::ErrorKind::Unsupported.into())
    }

    pub fn map_copy(len: usize, file: &File, offset: u64, _: bool, _: bool, _: bool) -> io::Result<MmapInner> {
        read_range(len, file, offset)
    }

    pub fn map_copy_read_only(len: usize, file: &File, offset: u64, _: bool, _: bool, _: bool) -> io::Result<MmapInner> {
        read_range(len, file, offset)
    }

    pub fn map_anon(len: usize, _: bool, _: bool, _: Option<u8>, _: bool) -> io::Result<MmapInner> {
        Ok(MmapInner { buf: vec![0; len] })
    }

    pub fn flush(&self, _: usize, _: usize) -> io::Result<()> {
        Ok(())
    }

    pub fn flush_async(&self, _: usize, _: usize) -> io::Result<()> {
        Ok(())
    }

    pub fn make_read_only(&mut self) -> io::Result<()> {
        Ok(())
    }

    pub fn make_exec(&mut self) -> io::Result<()> {
        Ok(())
    }

    pub fn make_mut(&mut self) -> io::Result<()> {
        Ok(())
    }

    #[inline]
    pub fn ptr(&self) -> *const u8 {
        self.buf.as_ptr()
    }

    #[inline]
    pub fn mut_ptr(&mut self) -> *mut u8 {
        self.buf.as_mut_ptr()
    }

    #[inline]
    pub fn len(&self) -> usize {
        self.buf.len()
    }

    pub fn check_safe_to_map(_file: &File, _offset: u64, _len: usize) -> Result<(), crate::MapIfSafeError> {
        Ok(())
    }
}

pub fn file_len(file: &File) -> io::Result<u64> {
    Ok(file.metadata()?.len())
}
