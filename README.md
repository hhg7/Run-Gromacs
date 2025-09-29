# Run-Gromacs
A Nextflow-like script to automate steps of Gromacs
```
usage: Automate running GROMACS simulations --production-input-file|-production
--pdb|-p --nvt-input-file|-nvt --npt-input-file|-npt --gmx
--emin-input-file|-emin [--help|-h] [--water|-w] [--overwrite|-o] [--ignore-H]
[--force-field|-ff]

Automating running GROMACS simulations, avoiding errors when moving from one
step to the next by a checked (not necessarily perfect!) pipeline

required named arguments:
  --production-input-file, -production PRODUCTION-INPUT-FILE      Production Input File
  --pdb, -p PDB                                                   Input PDB file; Perhaps better without H?
  --nvt-input-file, -nvt NVT-INPUT-FILE                           Equilibration run - temperature: constant Number of
                                                                    particles, Volume, and Temperature
  --npt-input-file, -npt NPT-INPUT-FILE                           Pressure Equilibration input file: Number of particles,
                                                                    Pressure, and Temperature are held constant
  --gmx GMX                                                       gmx executable
  --emin-input-file, -emin EMIN-INPUT-FILE                        Energy minimization input file

optional named arguments:
  --help, -h                        ? show this help message and exit
  --water, -w WATER                 ? Water model (e.g. "tip3p")
                                        Default: tip3p
  --overwrite, -o                   ? Overwrite old output files, by default off
                                        Default: 0
  --ignore-H                        ? pmx pdb2gmx ignore Hydrogens
                                        Default: 0
  --force-field, -ff FORCE-FIELD    ? The force field desired, e.g. "charmm27"
                                        Default: charmm27

Example:
perl 0.run.gromacs.pl --emin input/emin-charmm.0.mdp -npt input/npt-charmm.mdp
--gmx /home/con/prog/gromacs-2025.3/build/bin/gmx --nvt input/nvt-charmm.mdp
--pdb 1uao.noH.pdb -production input/md-charmm.mdp --o
```
