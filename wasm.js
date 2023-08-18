

var Module={
  arguments:['/working/Prelude.lean','/working/Prelude.olean'],
  preRun: [() => {
    FS.mkdir('/working');
    FS.mount(NODEFS, { root: '.' }, '/working');
  }]
};
