# braid/tests/config.nims
let siblingTripwire = thisDir() & "/../../tripwire/src"
if dirExists(siblingTripwire):
  switch("path", siblingTripwire)
switch("path", "../src")
switch("import", "tripwire/auto")
switch("define", "tripwireActive")
switch("define", "inProcessTest")
switch("define", "TripwireCapThreshold:500")
switch("warning", "UnusedImport:off")
