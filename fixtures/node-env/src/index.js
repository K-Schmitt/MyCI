// A project whose scripts are named differently (`type-check`) and whose test needs a build variable.
console.log(process.env.FIXTURE_FLAG === "1" ? "flag set" : "flag missing");
