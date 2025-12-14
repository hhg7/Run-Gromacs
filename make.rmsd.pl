#!/usr/bin/env perl

use 5.042;
no source::encoding;
use warnings FATAL => 'all';
use autodie ':default';
use SimpleFlow;
use File::Temp 'tempfile';
use Util 'list_regex_files';

open my $log, '>', __FILE__ . '.log';
sub rmsd_from_xtc ($xtc, $tpr, $stem) {
	my $datfile = "$stem.rmsd.dat";
	task({
		'dry.run'      => 1,
		'log.fh'       => $log,
		'input.files'  => [$xtc, $tpr],
		cmd            => "printf \"0\\n1\\n\" gmx rms -s $tpr -f $xtc -m $stem.rmsd.xpm -bin $datfile",
		'output.files' => ["$stem.rmsd.xpm", $datfile]
	});
	my $rmsdjson = $datfile;
	$rmsdjson =~ s/dat$/json/;
	my $py = File::Temp->new(DIR => '/tmp', SUFFIX => '.py', UNLINK => 1);
	say $py 'import numpy as np
import json
import sys

def ref_to_json_file(data, filename):
	json1=json.dumps(data)
	f = open(filename,"w+")
	print(json1,file=f)';
# 1. Read the binary data file
# The data is a raw dump of 32-bit floats (np.float32)
	say $py "binary_file = '$datfile' # Assuming you named the output with -bin as .dat";
	say $py 'data = np.fromfile(binary_file, dtype=np.float32)';
	say $py 'num_frames = int(np.sqrt(data.size))

if num_frames * num_frames != data.size:
	sys.exit("Error: Data size does not correspond to a square matrix. Check your input.")
else:# 3. Reshape the 1D array into the N x N matrix
	rmsd_matrix = data.reshape(num_frames, num_frames)';
	say $py	"ref_to_json_file(rmsd_matrix.tolist(), '$rmsdjson')";
	close $py;
	task({
		cmd            => 'python ' . $py->filename,
		'dry.run'      => 1,
		'input.files'  => [$py->filename],
		'log.fh'       => $log,
		'output.files' => [$rmsdjson],
	});
}

task({
	cmd      => 'which gmx',
	'log.fh' => $log,
}); # will die if cmd isn't installed; don't bother writing to log
my $dir = 'rmsd';
mkdir $dir unless -d $dir;
foreach my $xtc (list_regex_files('^3md\.\w+\.\d{2}.xtc$')) {
	my $group;
	if ($xtc =~ m/^3md\.(\w+)\.\d{2}\.xtc$/) {
		$group = $1;
	} else {
		die "$xtc failed regex.";
	}
	my $tpr_file = "3md.$group.tpr";
	die "$xtc: $tpr_file doesn't exist, isn't a file, or isn't readable" unless -f -r $tpr_file;
	my $stem = $xtc;
	$stem =~ s/\.xtc$//;
	$stem = "$dir/$stem";
	rmsd_from_xtc($xtc, $tpr_file, $stem);
}
