package XModem;
#
#	Simple Xmodem class.
#	Supports sending and receiving Xmodem 128 and 1024 byte packets.
#
#	$Id$
#	@author Jason Morriss <lifo101@gmail.com>
#

use strict;
use warnings;
use Carp;
use FileHandle;
use IO::Select;
use Data::Dumper;
# the require/import is used below to avoid this from showing as an
# error in my local IDE (I edit files remotely). Change this to 'use'
# if you want, but it won't change how anything works.
require Digest::CRC; import Digest::CRC;

our $VERSION = '1.0';
our $DEBUG = 0;

use constant {
	SOH	=> 0x01,	# start of header (128 bytes)
	STX	=> 0x02,	# start of header (1024 bytes)
	EOT	=> 0x04,	# end of transmission
	ACK	=> 0x06,	# acknowlegded
	NAK	=> 0x15,	# not acknowlegded
	NAKCRC	=> 0x43,	# not acknowledged (CRC)
	CAN	=> 0x18,	# cancel transmission
};

our @crctable;

sub new {
	my $proto = shift;
	my $class = ref($proto) || $proto;
	my $self = { };
	bless($self, $class);

	# must have 2 REF's or an even number of arguments
	if (@_ < 2 || @_ % 2 == 1 || (ref $_[0] and !ref $_[1])) {
		croak("Invalid usage in new(): Odd number of paramaters");
	}

	my %opt;
	while (ref $_[0] eq 'HASH') {	# merge hashref(s)
		%opt = (%opt, %{shift()});
	}
	if (@_ and ref $_[0]) {
		# if first option is a ref/glob then we know we have two
		# arguments that are specifying the in/out globs.
		$opt{in} = shift;
		$opt{out} = shift;
	}
	if (@_ and @_ % 2 == 0) {	# merge remaining named paramaters
		%opt = (%opt, @_);
		@_ = ();
	}
	%$self = %opt;

	$self->{retry} //= 10;
	$self->{timeout} //= 10;
	$self->{pad} //= "\x1a";

	$self->{in_select} = new IO::Select($self->{in});
	return $self;
}

# send a buffer or file to the connected handle.
# ->send('this is my string');
# ->send('path/to/filename', isfile => 1);
# ->send(..., verbose => 1, timeout => 10, retry => 10, wait_for_nak => 0);
sub send {
	my $self = shift;
	my %opt;
	$opt{buffer} = shift if @_;
	croak "Odd number of elements in send(...)" if @_ and @_ % 2 == 1;
	%opt = (%opt, @_) if @_;

	$opt{ymodem} //= 0;			# should the ymodem "block 0" be sent?
						# note: this does not support multiple
						# files at this time...
	$opt{verbose} //= $self->{verbose};
	$opt{timeout} //= $self->{timeout};	# how long to wait for NAK/ACK's
	$opt{retry} //= $self->{retry};		# how many times to retry
	$opt{isfile} //= 0;			# is the buffer really a filename?
	$opt{wait_for_nak} //= 1;		# wait for 1st NAK before starting?
	$opt{blocksize} //= 0;			# only 128 or 1024 is allowed (0 will autodetect based on NAK received)
	$opt{crc} //= 0;
	$opt{pad} //= $self->{pad};		# padding character to use
	#$opt{ascii} //= 0;			# convert NL to CR/LF (0x0D 0x0A)
	
	# override debug/verbose mode for calling block...
	local $self->{verbose} = $opt{verbose};
	local $self->{pad} = $opt{pad};
	
	croak "Invalid blocksize ($opt{blocksize})" unless !$opt{blocksize} or $opt{blocksize} == 128 or $opt{blocksize} == 1024;
	
	my $fh = new FileHandle;
	if ($opt{buffer} and !$opt{isfile}) {
		# treat the string like a file (Perl 5.8+)
		return unless open($fh, '<', \$opt{buffer});
	} else {
		return unless open($fh, '<', $opt{buffer});
	}
	$fh->binmode;
	$fh->autoflush(1);

	my $ack;
	# check for first NAK
	if ($opt{wait_for_nak} or $self->{in_select}->can_read(0)) {
		$self->bug("Waiting for initial NAK...\n");
		$ack = $self->_read(1);
		$ack = ord $ack if defined $ack;
		if (!defined $ack or ($ack ne NAK and $ack ne NAKCRC)) {
			$@ = "Waiting for initial package failed (invalid NAK [" . (defined $ack ? sprintf('0x%x', $ack) : '') . "])";
			return;
		}
		$self->bug("RECV: 0x%02x (%s)\n", $ack, chr $ack);
	}

	# determine block size. If we got NAKCRC then its 1024
	if (!$opt{blocksize}) {
		$opt{blocksize} = (!$ack or $ack == XModem::NAK) ? 128 : 1024;
	}
	$self->bug("Blocksize set to %d bytes\n", $opt{blocksize});

	my $total = 0;
	my $abstotal = 0;
	my $idx = 1;
	my $data = '';
	my $crc = ($opt{crc} or ($ack and $ack == XModem::NAKCRC));

	# The first block in ymodem is the "filename\0size"
	if ($opt{ymodem}) {
		my $try = 0;
		my $buffer = pack('a*', $opt{isfile} ? 'uploadfile' : $opt{buffer}) . pack('x');
		$buffer .= ($opt{isfile} ? (-s $opt{buffer}) : length($buffer));
		$buffer .= pack('x') x ((length($buffer)<=128 ? 128 : 1024) - length($buffer));
		my $pkt = $self->packet(0, $buffer, $crc);
		while (1) {
			$try++;
			$self->bug("Retry #%d for packet #%d.", $try, $idx) if $try > 1;
			$self->bug("SEND:\n%s", $self->tohex($pkt));
			if ($self->_write($pkt)) {
				# wait for ACK
				$ack = $self->_read(1);
				$ack = ord $ack if defined $ack;
				if (!defined $ack) {
					# TIMEOUT
					$@ = "Timed out waiting for ACK.";
					$self->bug($@);
					return;
				} elsif ($ack == XModem::NAK or $ack == XModem::NAKCRC) {
					$self->bug("NAK received for packet #0");
					if ($try >= $opt{retry}) {
						$@ = "Too many retry attempts. Canceling transfer.";
						return;
					}
					next;
				}
				$self->bug("RECV: 0x%02x (%s)\n", $ack, chr $ack);
				last if $ack == XModem::ACK;
			}
		}
	}

	while (my $bytes = $fh->read($data, $opt{blocksize}) > 0) {
		my $pkt = $self->packet($idx, $data, $crc);
		my $try = 0;
		$total += length($data);
		$abstotal += length($pkt);
		while (1) {
			$try++;
			$self->bug("Retry #%d for packet #%d.", $try, $idx) if $try > 1;
			$self->bug("SEND:\n%s", $self->tohex($pkt));
			if ($self->_write($pkt)) {
				# wait for ACK
				$ack = $self->_read(1);
				if (!defined $ack) {
					# TIMEOUT
					$@ = "Timed out waiting for ACK.";
					$self->bug($@);
					return;
				}
				$ack = ord $ack;
				$self->bug("RECV: 0x%02x (%s)\n", $ack, chr $ack);
				last if $ack == XModem::ACK;
				if ($ack == XModem::CAN) {
					$@ = "Transfer canceled by remote host.\n";
					return;
				} elsif ($ack == XModem::NAK or $ack == XModem::NAKCRC) {
					$self->bug("NAK received for packet #%d", $idx);
					if ($try >= $opt{retry}) {
						$@ = "Too many retry attempts. Canceling transfer.";
						return;
					}
					next;
				}
			} else {
				die "Error sending packet?!";
			}
			last;
		}
		$idx = 0 if ++$idx > 255;	# wrap to 0 after 255 is hit
		$data = '';
	}
	
	# end of transmission...
	my $eot = pack('c', XModem::EOT);
	$self->bug("SEND:\n%s", $self->tohex($eot));
	$self->_write($eot);
	
	# wait for ACK
	$ack = $self->_read(1);
	$self->bug("RECV: 0x%02x (%s)\n", ord $ack, $ack);
	
	# send another EOT and we're done...
	$self->bug("SEND:\n%s", $self->tohex($eot));
	$self->_write($eot);

	# wait for ACK
	$ack = $self->_read(1);
	$self->bug("RECV: 0x%02x (%s)\n", ord $ack, $ack);

	if ($opt{ymodem} and ord $ack == XModem::ACK) {
		my $pkt = $self->packet(0, "\0" x 128, $crc);
		$self->bug("SEND:\n%s", $self->tohex($pkt));
		$self->_write($pkt);
		$ack = $self->_read(1);
		$self->bug("RECV: 0x%02x (%s)\n", ord $ack, $ack);
	}

	$self->bug("Transmission complete (%d bytes)\n", $total);
	return $total;
}

sub sendfile { shift->send(@_, isfile => 1) }

sub get {
	my $self = shift;
	my %opt;
	$opt{buffer} = shift if @_;
	croak "Odd number of elements in get(...)" if @_ and @_ % 2 == 1;
	%opt = (%opt, @_) if @_;

	$opt{append} //= 0;			# append to output?
	$opt{verbose} //= $self->{verbose};
	$opt{timeout} //= $self->{timeout};	# how long to wait for NAK/ACK's
	$opt{retry} //= $self->{retry};		# how many times to retry
	$opt{isfile} //= 0;			# is the buffer really a filename?
	$opt{blocksize} //= 128;		# only 128 or 1024 is allowed
	$opt{crc} //= 0;			# require CRC16?
	$opt{ascii} //= 0;			# ascii mode?
	
	# override debug/verbose mode for calling block...
	local $self->{verbose} = $opt{verbose};

	croak "Invalid blocksize ($opt{blocksize}) must be 128 or 1024" unless $opt{blocksize} == 128 or $opt{blocksize} == 1024;

	my $fh = new FileHandle;
	my $mode = $opt{append} ? '>>' : '>';
	if ($opt{buffer} and !$opt{isfile}) {
		# treat the string like a file (Perl 5.8+)
		return $self->error($!) unless open($fh, $mode, \$opt{buffer});
	} else {
		$self->bug("Opening file $opt{buffer} ...");
		return $self->error($!) unless open($fh, $mode, $opt{buffer});
	}
	$fh->binmode;
	$fh->autoflush(1);

	my $nak = pack('c', $opt{crc} ? XModem::NAKCRC : XModem::NAK);
	$self->bug("SEND (NAK):\n%s", $self->tohex($nak));
	if (!$self->_write($nak)) {
		return $self->error("Timeout sending NAK.");
	}
	
	my $ack;
	my $data;
	my $crc;
	my $total = 0;
	my $abstotal = 0;
	my $idx = 1;
	my $EOT = 0;
	while (1) {
		my $hdr = $self->_read(1);
		if (!defined $hdr) {
			close($fh);
			# TODO: unlink file too?
			return $self->error("Timeout reading header");
		}
		$self->bug("RECV (hdr):\n%s", $self->tohex($hdr));
		$hdr = ord $hdr;
		$abstotal++;

		if ($hdr == XModem::SOH or $hdr == XModem::STX) {
			my $buf = $self->_read(2) or return $self->error("Timeout reading numchk header");
			$abstotal += 2;
			$self->bug("RECV (numchk):\n%s", $self->tohex($buf));
			my ($n1, $n2) = map { ord } split(//, $buf, 2);
			$n2 = 255 - $n2;	# one's compliment of the byte
			return $self->error("Packet sequence error at idx $idx (got $n1)") if $n1 != $idx;
			return $self->error("Packet sequence checksum error at idx $idx ($n1 <> $n2)") if $n1 != $n2;

			$opt{blocksize} = ($hdr == XModem::SOH) ? 128 : 1024;
			$data = $self->_read($opt{blocksize}) or return $self->error("Timeout reading data");
			$self->bug("RECV (packet):\n%s", $self->tohex($data));
			$abstotal += length($data);
			$total += length($data);

			$crc = $self->_read($opt{crc} ? 2 : 1);
			$self->bug("RECV (crc):\n%s",  $self->tohex($crc));
			$abstotal += length($crc);

			$ack = pack 'c', XModem::ACK;

			# verify checksum
			if (length($crc) == 1) {
				my $ours = $self->checksum($data);
				my $theirs = ord $crc;
				$self->bug("Checksum 0x%02x == 0x%02x", $ours, $theirs);
				if ($ours != $theirs) {
					$self->bug("Checksum failed (0x%02x <> 0x%02x)", $ours, $theirs);
					$ack = $nak;
				}
			} else {
				my $ours = $self->crc16($data);
				my $theirs = unpack('n', $crc);
				$self->bug("CRC16 0x%04x == 0x%04x", $ours, $theirs);
				if ($ours != $theirs) {
					$self->bug("CRC16 failed (0x%04x <> 0x%04x)", $ours, $theirs);
					$ack = $nak;
				}
			}

			# if the packet was verified write the data packet to
			# the file... Remove trailing ^Z on ascii files.
			if ($ack ne $nak) {
				if ($opt{ascii}) {
					my $len = length($data);
					$data =~ s/\cZ+$//;
					$total -= $len-length($data);
				}
				print $fh $data;
			}

			# send next ack/nak
			$self->bug("SEND (ACK):\n%s", $self->tohex($ack));
			if (!$self->_write($ack)) {
				return $self->error("Timeout sending ACK.");
			}
			next if ord $ack != XModem::ACK;
			
		} elsif ($hdr == XModem::EOT) {
			$EOT++;
			if ($EOT == 1) {
				$self->bug("End of transmission received (EOT1)");
				$self->_write(pack 'c', XModem::NAK);
			} else {
				$self->bug("End of transmission (EOT2)");
				$self->_write(pack 'c', XModem::ACK);
				close($fh);
				last;
			}

		} elsif ($hdr == XModem::CAN) {
			last;			
		}

		$idx = 0 if ++$idx > 255;	# wrap to 0 after 255 is hit
	}

	return $total;
}
sub getfile { shift->get(@_, isfile => 1) }

# return a packed packet for transmission
sub packet {
	my ($self, $idx, $data, $crc) = @_;
	my $len = length($data);
	my $size = $len <= 128 ? 128 : 1024;
	my $hdr = $size==128 ? XModem::SOH : XModem::STX;
	my $pkt = pack('CCC', $hdr, $idx, 255-$idx);
	if ($len < $size) { # pad data to the maximum block size
		#$data .= "\x00" x ($size - $len);
		#$data .= "\x1a" x ($size - $len);
		#$data .= "\xff" x ($size - $len);
		$data .= $self->{pad} x ($size - $len);
	}
	$pkt .= pack('a*', $data);
	if ($crc) {
		$pkt .= pack('n', $self->crc16($data));
	} else {
		$pkt .= pack('C', $self->checksum($data));
	}
	return $pkt;
}

# send a message to the remote end; returns the total bytes written.
sub _write { syswrite($_[0]->{out}, $_[1]) }

# read a message from the remote end; will retry up to the max set.
# returns the buffer read.
sub _read {
	my ($self, $len) = @_;
	my $try = 0;
	$len //= 1;
	return if $len < 1;
	while (1) {
		$try++;
		if (my @ready = $self->{in_select}->can_read($self->{timeout})) {
			my $s = '';
			sysread($self->{in}, $s, $len);
			return $s;
		}
		$self->bug("READ TIMEOUT (try %d)", $try);
		# return nothing if we've tried too many times
		return if $try >= $self->{retry};
	}
}

# return checksum for string provided
sub checksum {
	my $self = shift;
	my $str = shift;
	my $c = 0;
	$c += $_ for unpack('c*', $str);
	return $c %= 256;
}

# return CRC16 for string provided
sub crc16 { new Digest::CRC(width => 16, poly => 0x1021)->add($_[1])->digest }

# return a "hex dump" of the string provided
sub tohex {
	my $self = shift;
	my $offset = 0;
	my (@array, $format);
	my $output = '';
	foreach my $data (unpack("a16" x (length($_[0])/16)."a*", $_[0])) {
		my $len = length($data);
		if ($len == 16) {
			@array = unpack('N4', $data);
			$format="0x%08x (%05d)   %08x %08x %08x %08x   %s\n";
		} else {
			@array = unpack('C*', $data);
			$_ = sprintf "%2.2x", $_ for @array;
			push(@array, '  ') while $len++ < 16;
			$format="0x%08x (%05d)   %s%s%s%s %s%s%s%s %s%s%s%s %s%s%s%s   %s\n";
		} 
		$data =~ tr/\0-\37\177-\377/./;
		$output .= sprintf($format,$offset,$offset,@array,$data);
		$offset += 16;
	}
	return $output;
}

# debug output
sub bug {
	my $self = shift;
	return unless $self->{verbose};
	chomp(my $fmt = shift);
	print STDERR sprintf $fmt . "\n", @_;
}

sub error {
	my ($self, $err) = @_;
	$@ = $err;
	$self->bug($err);
	return;	# undef
}

1;
