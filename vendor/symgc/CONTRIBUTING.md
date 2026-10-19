# Contributing

steadygc is a preview. The most useful contribution is a measurement or a bug report from a machine, an operating
system or a program the author does not have.

## Reporting

[`guide/testing.md`](guide/testing.md) has a report template (machine, OS, compiler, setup, flags, result). Attach the
whole output of `bench/correctness.sh` and of `bench/compare.sh` for your program. For a crash, build the collector in
verifier mode (`-version=Symgc_verify`) and attach the backtrace; for a pause, build with `-version=Symgc_phase_trace`
and attach the trace, which prints every phase of every collection with its duration.

## Changing the collector

* Build the unit tests with the command in `guide/testing.md` and run them; add a test with the change.
* Run `bench/correctness.sh`. A change that touches marking, the sweep or the allocator also needs a run of the
  benchmarks it can affect (`bench/compare.sh`), before and after, on an idle machine. Say what was run and what was
  only compiled.
* A change to the barrier or to the card table also needs `bench/cards_window.d` and `bench/cards_precision.d`, and
  `mark_race_glue.d` with the compiler pass in use (`bench/README.md`).
* Keep a commit to one change, and put the measurement that justifies it in the message.
* Documentation is English, short, and says what was measured and what was only expected.

## Platforms

Windows, macOS, iOS and Android are the open ports; `guide/platforms.md` lists what each is missing and
`guide/android.md` is the plan for the first Android session. Do not report a platform as working because the code
compiles for it.
