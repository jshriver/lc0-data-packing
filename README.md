The fetch_and_rescore.py can be used to process a subset of the lczer training subset.  This way you can run it on multiple machines with 
each one running a slice.

Example:

./fetch_and_rescore.py --syzygy ~/syzygy/3-4-5/   --from training-run2-test91-20260525-0917.tar   --to training-run2-test91-20260610-1317.tar
