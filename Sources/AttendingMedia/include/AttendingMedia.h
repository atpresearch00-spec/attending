#pragma once
// Entry point installed as a Perl XSUB. Attending runs it inside /usr/bin/perl
// because macOS only serves Now Playing metadata to Apple-signed processes.
void attending_media_run(void *perl, void *cv);
