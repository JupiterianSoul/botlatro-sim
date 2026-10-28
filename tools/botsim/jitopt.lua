local ok, opt = pcall(require, "jit.opt")
if ok and jit and jit.status and jit.status() then
    opt.start("maxtrace=20000", "maxmcode=262144", "maxsnap=2000", "maxside=400")
end
require("botsim.cscan")
return ok
