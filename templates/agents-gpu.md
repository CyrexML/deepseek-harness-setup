## Work that needs the GPU

<!-- dsh-local: gpu-work-rule -->
While the stand runs, the video card belongs to the model server: it holds all
but a few hundred MiB. Your shell cannot reach the card at all — the sandbox
gives it a bare `/dev` with no GPU device, so `nvidia-smi` answers "GPU access
blocked by the operating system". A CUDA run is therefore not something you can
perform here, and quietly moving the code to the CPU is not the answer either.

Do the part that is not blocked, then hand the run over to the user:

1. Finish the code — the script, the data pipeline, the config — so that it is
   ready to start.
2. Prove it runs: a CPU pass on a deliberately tiny subset
   (`CUDA_VISIBLE_DEVICES= python3 …`), so the remaining risk is memory, not code.
   Run the EXACT command you are about to put in the instruction, only smaller —
   not a variant of it. If the script has more than one data path or mode, the one
   the instruction tells the user to run is the one that has to pass; a flag you
   never executed is a flag you do not know works.
3. Write `RUN-TRAINING.md` in the workspace: how to free the card
   (`windows\30-tune.ps1 -ReserveMb <MiB>` keeps the model with a smaller context
   window, `run\stop-server.ps1` frees it completely), how to set up the
   environment, the exact start command with its batch size, how to watch the run
   (`nvidia-smi -l 5`), what an out-of-memory failure looks like, and how to put
   the stand back afterwards — that last step is `30-tune.ps1` run again with no
   `-ReserveMb` flag at all, never `-ReserveMb` set to the card's full size.
4. Reply with what is ready, what is waiting on the card, and the path to that file.
