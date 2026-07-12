declare name "DeMoD Amp Head";
declare version "1.0.0";
declare author "DeMoD LLC";
declare license "DeMoD Commercial Source License";
declare description "Virtual analog tube amp head — Bassman topology with ZDF preamp, interactive tone stack, sag, presence and depth";
declare options "[midi:on]";

import("stdfaust.lib");
sk = library("demod_skill.lib");
va = library("demod_va.lib");

process = va.ampHead;