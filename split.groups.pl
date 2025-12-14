#!/usr/bin/env perl

use 5.042;
no source::encoding;
use warnings FATAL => 'all';
use autodie ':default';
use SimpleFlow; # task
use Util qw(list_regex_files);

open my $log, '>', __FILE__ . '.log';
sub remove_backups {
	foreach my $backup (list_regex_files('^#(?:3|chi)')) {
		unlink $backup; # these can interfere with future commands
		say2("deleted $backup", $log);
	}
	unlink 'chi.log' if -f 'chi.log';
}
remove_backups();
=don't delete!
task({
	'log.fh' => $log,
	cmd      => 'echo 4 | gmx convert-tpr -s 3md.tpr -o 3md.Ligand.tpr -n cpx.ndx',
});
task({
	'log.fh' => $log,
	cmd      => "echo 4 | gmx trjconv -s 3md.Ligand.tpr -f 3md_out01.xtc -o 3md.ligand.01.xtc -n cpx.ndx"
});
task({
	'log.fh' => $log,
	cmd      => "echo 4 | gmx trjconv -s 3md.Ligand.tpr -f 3md.Ligand.01.xtc -o 3md.Ligand.01.gro"
});
=cut

mkdir 'xvg' unless -d 'xvg';
foreach my $n (1..9) {
	$n = sprintf '%02d', $n;
	my %index = (
		Ligand         => 4,
#		Ligand_CA      => 3,
		Receptor       => 2,
#		BindingSite_CA => 5,
#		BindingSite    => 6
	);
	while (my ($group, $val) = each %index) {
		my $g_tpr = "3md.$group.tpr";
		task({
			cmd           => "echo $val | gmx convert-tpr -s 3md.tpr -o $g_tpr -n cpx.ndx",
			'input.files' => ['3md.tpr', 'cpx.ndx'],
			'log.fh'      => $log,
			'output.files'=> $g_tpr, # only do this once
			overwrite     => 'true'
		});
		my $subset_xtc = "3md.$group.$n.xtc";
		task({
			cmd            => "echo $val | gmx trjconv -s $g_tpr -f 3md_out$n.xtc -o $subset_xtc -n cpx.ndx",
			'input.files'  => ["3md_out$n.xtc", $g_tpr],
			'log.fh'       => $log,
			'output.files' => $subset_xtc,
			overwrite      => 'true'
		});
		mkdir "xvg/$group" unless -d "xvg/$group";
		my $dir = "xvg/$group/" . sprintf '%u', $n;
		mkdir $dir unless -d $dir;
		remove_backups();
		task({
			cmd            => "gmx chi -s $g_tpr -f $subset_xtc -phi -psi -all",
			'log.fh'       => $log,
			'input.files'  => $subset_xtc,
			overwrite      => 'true'
		});
		foreach my $f (list_regex_files('\.xvg$')) {
			rename $f, "$dir/$f";
			say2("Moved $f to $dir/$f", $log);
		}
		remove_backups();
	}
}
