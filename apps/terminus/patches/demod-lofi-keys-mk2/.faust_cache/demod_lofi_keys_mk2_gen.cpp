/* ------------------------------------------------------------
author: "DeMoD LLC"
license: "(c) DeMoD LLC"
name: "DeMoD LoFi Keys MkII"
version: "0.4.1"
Code generated with Faust 2.83.1 (https://faust.grame.fr)
Compilation options: -a /home/asher/Downloads/demod-fx/playback_midi/faust_render/arch/capi.cpp -lang cpp -fpga-mem-th 4 -ct 1 -es 1 -mcd 16 -mdd 1024 -mdy 33 -single -ftz 0
------------------------------------------------------------ */

#ifndef  __mydsp_H__
#define  __mydsp_H__

/*
 * capi.cpp — Faust architecture file: C API export
 * =================================================
 * Used as: faust -a capi.cpp -lang cpp synth.dsp -o synth_gen.cpp
 * Then:    g++ -shared -fPIC synth_gen.cpp -o synth.so
 *
 * Exports a flat C API so Python ctypes can drive any Faust DSP.
 *
 * Standard MIDI convention (matched by engine.py):
 *   "freq"  / "h:.../freq"  → note frequency in Hz
 *   "gate"  / "h:.../gate"  → gate 0.0 / 1.0
 *   "gain"  / "h:.../gain"  → velocity 0.0–1.0
 */

#include <math.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <string>
#include <vector>
#include <algorithm>

/* ── Faust boilerplate ─────────────────────────────────────────────────── */

#ifndef FAUSTFLOAT
#define FAUSTFLOAT float
#endif

#define BUFFER_SIZE 64

/* Suppress Faust's default UI machinery — we supply our own below. */
class UI {
public:
    virtual ~UI() {}
    virtual void openTabBox(const char*)        {}
    virtual void openHorizontalBox(const char*) {}
    virtual void openVerticalBox(const char*)   {}
    virtual void closeBox()                     {}
    virtual void addButton(const char*, FAUSTFLOAT*)                           {}
    virtual void addCheckButton(const char*, FAUSTFLOAT*)                      {}
    virtual void addVerticalSlider(const char*, FAUSTFLOAT*, FAUSTFLOAT,
                                   FAUSTFLOAT, FAUSTFLOAT, FAUSTFLOAT)        {}
    virtual void addHorizontalSlider(const char*, FAUSTFLOAT*, FAUSTFLOAT,
                                     FAUSTFLOAT, FAUSTFLOAT, FAUSTFLOAT)      {}
    virtual void addNumEntry(const char*, FAUSTFLOAT*, FAUSTFLOAT,
                             FAUSTFLOAT, FAUSTFLOAT, FAUSTFLOAT)              {}
    virtual void addHorizontalBargraph(const char*, FAUSTFLOAT*,
                                       FAUSTFLOAT, FAUSTFLOAT)                {}
    virtual void addVerticalBargraph(const char*, FAUSTFLOAT*,
                                     FAUSTFLOAT, FAUSTFLOAT)                  {}
    virtual void declare(FAUSTFLOAT*, const char*, const char*)               {}
};

class Meta {
public:
    virtual ~Meta() {}
    virtual void declare(const char*, const char*) {}
};

/* dsp base class — generated code inherits from this. */
class dsp {
public:
    virtual ~dsp() {}
    virtual int  getNumInputs()  = 0;
    virtual int  getNumOutputs() = 0;
    virtual void buildUserInterface(UI*) = 0;
    virtual int  getSampleRate() = 0;
    virtual void init(int)       = 0;
    virtual void instanceInit(int) = 0;
    virtual void instanceConstants(int) = 0;
    virtual void instanceResetUserInterface() = 0;
    virtual void instanceClear()   = 0;
    virtual dsp* clone()           = 0;
    virtual void metadata(Meta*)   = 0;
    virtual void compute(int, FAUSTFLOAT**, FAUSTFLOAT**) = 0;
};

/* ── Paste generated DSP class ─────────────────────────────────────────── */

#ifndef FAUSTFLOAT
#define FAUSTFLOAT float
#endif 

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <math.h>

#ifndef FAUSTCLASS 
#define FAUSTCLASS mydsp
#endif

#ifdef __APPLE__ 
#define exp10f __exp10f
#define exp10 __exp10
#endif

#if defined(_WIN32)
#define RESTRICT __restrict
#else
#define RESTRICT __restrict__
#endif

static float mydsp_faustpower2_f(float value) {
	return value * value;
}
static float mydsp_faustpower3_f(float value) {
	return value * value * value;
}
static float mydsp_faustpower4_f(float value) {
	return value * value * value * value;
}

class mydsp : public dsp {
	
 private:
	
	int fSampleRate;
	float fConst0;
	float fConst1;
	float fConst2;
	float fConst3;
	float fConst4;
	float fConst5;
	float fConst6;
	float fConst7;
	float fConst8;
	float fConst9;
	float fConst10;
	float fConst11;
	float fConst12;
	float fConst13;
	float fConst14;
	float fConst15;
	float fConst16;
	float fConst17;
	float fConst18;
	float fConst19;
	float fConst20;
	float fConst21;
	FAUSTFLOAT fButton0;
	float fVec0[2];
	int iRec1[2];
	float fConst22;
	float fRec2[2];
	int iRec3[2];
	float fRec0[5];
	float fConst23;
	float fConst24;
	float fConst25;
	float fRec8[2];
	float fVec1[2];
	float fConst26;
	float fRec7[2];
	float fConst27;
	float fConst28;
	FAUSTFLOAT fHslider0;
	float fRec9[2];
	FAUSTFLOAT fHslider1;
	FAUSTFLOAT fHslider2;
	float fRec10[2];
	FAUSTFLOAT fHslider3;
	float fRec11[2];
	FAUSTFLOAT fHslider4;
	float fRec12[2];
	float fVec2[2];
	float fRec14[2];
	FAUSTFLOAT fHslider5;
	FAUSTFLOAT fHslider6;
	float fRec15[2];
	FAUSTFLOAT fHslider7;
	float fRec16[2];
	float fConst29;
	float fConst30;
	float fConst31;
	float fConst32;
	float fRec17[2];
	float fRec13[3];
	float fRec18[3];
	FAUSTFLOAT fHslider8;
	float fRec19[2];
	float fRec20[3];
	float fRec21[3];
	float fRec22[3];
	float fConst33;
	FAUSTFLOAT fHslider9;
	float fRec24[2];
	float fRec23[2];
	float fConst34;
	float fConst35;
	FAUSTFLOAT fHslider10;
	float fRec25[2];
	float fRec26[2];
	
 public:
	mydsp() {
	}
	
	mydsp(const mydsp&) = default;
	
	virtual ~mydsp() = default;
	
	mydsp& operator=(const mydsp&) = default;
	
	void metadata(Meta* m) { 
		m->declare("author", "DeMoD LLC");
		m->declare("basics.lib/name", "Faust Basic Element Library");
		m->declare("basics.lib/sAndH:author", "Romain Michon");
		m->declare("basics.lib/version", "1.22.0");
		m->declare("compile_options", "-a /home/asher/Downloads/demod-fx/playback_midi/faust_render/arch/capi.cpp -lang cpp -fpga-mem-th 4 -ct 1 -es 1 -mcd 16 -mdd 1024 -mdy 33 -single -ftz 0");
		m->declare("description", "Modeled tine electric piano through a modeled tape/vinyl medium with Sierpinski resonance.");
		m->declare("envelopes.lib/adsr:author", "Yann Orlarey and Andrey Bundin");
		m->declare("envelopes.lib/author", "GRAME");
		m->declare("envelopes.lib/copyright", "GRAME");
		m->declare("envelopes.lib/license", "LGPL with exception");
		m->declare("envelopes.lib/name", "Faust Envelope Library");
		m->declare("envelopes.lib/version", "1.3.0");
		m->declare("filename", "demod_lofi_keys_mk2.dsp");
		m->declare("filters.lib/bandpass0_bandstop1:author", "Julius O. Smith III");
		m->declare("filters.lib/bandpass0_bandstop1:copyright", "Copyright (C) 2003-2019 by Julius O. Smith III <jos@ccrma.stanford.edu>");
		m->declare("filters.lib/bandpass0_bandstop1:license", "MIT-style STK-4.3 license");
		m->declare("filters.lib/bandpass:author", "Julius O. Smith III");
		m->declare("filters.lib/bandpass:copyright", "Copyright (C) 2003-2019 by Julius O. Smith III <jos@ccrma.stanford.edu>");
		m->declare("filters.lib/bandpass:license", "MIT-style STK-4.3 license");
		m->declare("filters.lib/fir:author", "Julius O. Smith III");
		m->declare("filters.lib/fir:copyright", "Copyright (C) 2003-2019 by Julius O. Smith III <jos@ccrma.stanford.edu>");
		m->declare("filters.lib/fir:license", "MIT-style STK-4.3 license");
		m->declare("filters.lib/iir:author", "Julius O. Smith III");
		m->declare("filters.lib/iir:copyright", "Copyright (C) 2003-2019 by Julius O. Smith III <jos@ccrma.stanford.edu>");
		m->declare("filters.lib/iir:license", "MIT-style STK-4.3 license");
		m->declare("filters.lib/lowpass0_highpass1", "Copyright (C) 2003-2019 by Julius O. Smith III <jos@ccrma.stanford.edu>");
		m->declare("filters.lib/lowpass0_highpass1:author", "Julius O. Smith III");
		m->declare("filters.lib/lowpass:author", "Julius O. Smith III");
		m->declare("filters.lib/lowpass:copyright", "Copyright (C) 2003-2019 by Julius O. Smith III <jos@ccrma.stanford.edu>");
		m->declare("filters.lib/lowpass:license", "MIT-style STK-4.3 license");
		m->declare("filters.lib/name", "Faust Filters Library");
		m->declare("filters.lib/pole:author", "Julius O. Smith III");
		m->declare("filters.lib/pole:copyright", "Copyright (C) 2003-2019 by Julius O. Smith III <jos@ccrma.stanford.edu>");
		m->declare("filters.lib/pole:license", "MIT-style STK-4.3 license");
		m->declare("filters.lib/tf1:author", "Julius O. Smith III");
		m->declare("filters.lib/tf1:copyright", "Copyright (C) 2003-2019 by Julius O. Smith III <jos@ccrma.stanford.edu>");
		m->declare("filters.lib/tf1:license", "MIT-style STK-4.3 license");
		m->declare("filters.lib/tf1s:author", "Julius O. Smith III");
		m->declare("filters.lib/tf1s:copyright", "Copyright (C) 2003-2019 by Julius O. Smith III <jos@ccrma.stanford.edu>");
		m->declare("filters.lib/tf1s:license", "MIT-style STK-4.3 license");
		m->declare("filters.lib/tf2:author", "Julius O. Smith III");
		m->declare("filters.lib/tf2:copyright", "Copyright (C) 2003-2019 by Julius O. Smith III <jos@ccrma.stanford.edu>");
		m->declare("filters.lib/tf2:license", "MIT-style STK-4.3 license");
		m->declare("filters.lib/tf2sb:author", "Julius O. Smith III");
		m->declare("filters.lib/tf2sb:copyright", "Copyright (C) 2003-2019 by Julius O. Smith III <jos@ccrma.stanford.edu>");
		m->declare("filters.lib/tf2sb:license", "MIT-style STK-4.3 license");
		m->declare("filters.lib/version", "1.7.1");
		m->declare("license", "(c) DeMoD LLC");
		m->declare("maths.lib/author", "GRAME");
		m->declare("maths.lib/copyright", "GRAME");
		m->declare("maths.lib/license", "LGPL with exception");
		m->declare("maths.lib/name", "Faust Math Library");
		m->declare("maths.lib/version", "2.9.0");
		m->declare("name", "DeMoD LoFi Keys MkII");
		m->declare("noises.lib/name", "Faust Noise Generator Library");
		m->declare("noises.lib/version", "1.5.0");
		m->declare("options", "[midi:on][nvoices:8]");
		m->declare("physmodels.lib/name", "Faust Physical Models Library");
		m->declare("physmodels.lib/version", "1.2.0");
		m->declare("platform.lib/name", "Generic Platform Library");
		m->declare("platform.lib/version", "1.3.0");
		m->declare("signals.lib/name", "Faust Signal Routing Library");
		m->declare("signals.lib/version", "1.6.0");
		m->declare("version", "0.4.1");
	}

	virtual int getNumInputs() {
		return 0;
	}
	virtual int getNumOutputs() {
		return 1;
	}
	
	static void classInit(int sample_rate) {
	}
	
	virtual void instanceConstants(int sample_rate) {
		fSampleRate = sample_rate;
		fConst0 = std::min<float>(1.92e+05f, std::max<float>(1.0f, static_cast<float>(fSampleRate)));
		fConst1 = std::tan(12566.371f / fConst0);
		fConst2 = std::sqrt(4.0f * mydsp_faustpower2_f(fConst0) * std::tan(4712.389f / fConst0) * fConst1);
		fConst3 = mydsp_faustpower2_f(fConst2);
		fConst4 = 1.0f / fConst0;
		fConst5 = mydsp_faustpower3_f(fConst4) * fConst3;
		fConst6 = fConst0 * fConst1;
		fConst7 = 2.0f * fConst6 - 0.5f * (fConst3 / fConst6);
		fConst8 = fConst7 * (11.313708f / fConst0 + 2.828427f * fConst5);
		fConst9 = mydsp_faustpower2_f(fConst7);
		fConst10 = mydsp_faustpower2_f(fConst4);
		fConst11 = mydsp_faustpower4_f(fConst4) * mydsp_faustpower4_f(fConst2);
		fConst12 = fConst11 + fConst10 * (4.0f * fConst9 + 8.0f * fConst3);
		fConst13 = fConst12 + (16.0f - fConst8);
		fConst14 = 5.656854f * fConst5;
		fConst15 = 22.627417f / fConst0;
		fConst16 = 4.0f * fConst11;
		fConst17 = fConst16 + fConst7 * (fConst15 - fConst14) + -64.0f;
		fConst18 = 6.0f * fConst11 + (96.0f - fConst10 * (8.0f * fConst9 + 16.0f * fConst3));
		fConst19 = fConst16 + fConst7 * (fConst14 - fConst15) + -64.0f;
		fConst20 = fConst8 + fConst12 + 16.0f;
		fConst21 = 1.0f / fConst20;
		fConst22 = 1.0f / std::max<float>(1.0f, 0.01f * fConst0);
		fConst23 = 0.25f * (fConst10 * fConst9 / fConst20);
		fConst24 = 1.0f / std::tan(1099.5574f / fConst0);
		fConst25 = 1.0f - fConst24;
		fConst26 = 1.0f / (fConst24 + 1.0f);
		fConst27 = 44.1f / fConst0;
		fConst28 = 1.0f - fConst27;
		fConst29 = 0.47f * fConst0;
		fConst30 = 6.2831855f / fConst0;
		fConst31 = 1.0f / std::max<float>(1.0f, 0.0018f * fConst0);
		fConst32 = 3.1415927f / fConst0;
		fConst33 = 0.85f * fConst0;
		fConst34 = 1.0f / std::max<float>(1.0f, 0.3f * fConst0);
		fConst35 = 0.9f / std::max<float>(1.0f, 0.6f * fConst0);
	}
	
	virtual void instanceResetUserInterface() {
		fButton0 = static_cast<FAUSTFLOAT>(0.0f);
		fHslider0 = static_cast<FAUSTFLOAT>(0.25f);
		fHslider1 = static_cast<FAUSTFLOAT>(0.8f);
		fHslider2 = static_cast<FAUSTFLOAT>(0.35f);
		fHslider3 = static_cast<FAUSTFLOAT>(0.003f);
		fHslider4 = static_cast<FAUSTFLOAT>(0.3f);
		fHslider5 = static_cast<FAUSTFLOAT>(2.2e+02f);
		fHslider6 = static_cast<FAUSTFLOAT>(3.0f);
		fHslider7 = static_cast<FAUSTFLOAT>(1.6f);
		fHslider8 = static_cast<FAUSTFLOAT>(0.4f);
		fHslider9 = static_cast<FAUSTFLOAT>(5.0f);
		fHslider10 = static_cast<FAUSTFLOAT>(0.55f);
	}
	
	virtual void instanceClear() {
		for (int l0 = 0; l0 < 2; l0 = l0 + 1) {
			fVec0[l0] = 0.0f;
		}
		for (int l1 = 0; l1 < 2; l1 = l1 + 1) {
			iRec1[l1] = 0;
		}
		for (int l2 = 0; l2 < 2; l2 = l2 + 1) {
			fRec2[l2] = 0.0f;
		}
		for (int l3 = 0; l3 < 2; l3 = l3 + 1) {
			iRec3[l3] = 0;
		}
		for (int l4 = 0; l4 < 5; l4 = l4 + 1) {
			fRec0[l4] = 0.0f;
		}
		for (int l5 = 0; l5 < 2; l5 = l5 + 1) {
			fRec8[l5] = 0.0f;
		}
		for (int l6 = 0; l6 < 2; l6 = l6 + 1) {
			fVec1[l6] = 0.0f;
		}
		for (int l7 = 0; l7 < 2; l7 = l7 + 1) {
			fRec7[l7] = 0.0f;
		}
		for (int l8 = 0; l8 < 2; l8 = l8 + 1) {
			fRec9[l8] = 0.0f;
		}
		for (int l9 = 0; l9 < 2; l9 = l9 + 1) {
			fRec10[l9] = 0.0f;
		}
		for (int l10 = 0; l10 < 2; l10 = l10 + 1) {
			fRec11[l10] = 0.0f;
		}
		for (int l11 = 0; l11 < 2; l11 = l11 + 1) {
			fRec12[l11] = 0.0f;
		}
		for (int l12 = 0; l12 < 2; l12 = l12 + 1) {
			fVec2[l12] = 0.0f;
		}
		for (int l13 = 0; l13 < 2; l13 = l13 + 1) {
			fRec14[l13] = 0.0f;
		}
		for (int l14 = 0; l14 < 2; l14 = l14 + 1) {
			fRec15[l14] = 0.0f;
		}
		for (int l15 = 0; l15 < 2; l15 = l15 + 1) {
			fRec16[l15] = 0.0f;
		}
		for (int l16 = 0; l16 < 2; l16 = l16 + 1) {
			fRec17[l16] = 0.0f;
		}
		for (int l17 = 0; l17 < 3; l17 = l17 + 1) {
			fRec13[l17] = 0.0f;
		}
		for (int l18 = 0; l18 < 3; l18 = l18 + 1) {
			fRec18[l18] = 0.0f;
		}
		for (int l19 = 0; l19 < 2; l19 = l19 + 1) {
			fRec19[l19] = 0.0f;
		}
		for (int l20 = 0; l20 < 3; l20 = l20 + 1) {
			fRec20[l20] = 0.0f;
		}
		for (int l21 = 0; l21 < 3; l21 = l21 + 1) {
			fRec21[l21] = 0.0f;
		}
		for (int l22 = 0; l22 < 3; l22 = l22 + 1) {
			fRec22[l22] = 0.0f;
		}
		for (int l23 = 0; l23 < 2; l23 = l23 + 1) {
			fRec24[l23] = 0.0f;
		}
		for (int l24 = 0; l24 < 2; l24 = l24 + 1) {
			fRec23[l24] = 0.0f;
		}
		for (int l25 = 0; l25 < 2; l25 = l25 + 1) {
			fRec25[l25] = 0.0f;
		}
		for (int l26 = 0; l26 < 2; l26 = l26 + 1) {
			fRec26[l26] = 0.0f;
		}
	}
	
	virtual void init(int sample_rate) {
		classInit(sample_rate);
		instanceInit(sample_rate);
	}
	
	virtual void instanceInit(int sample_rate) {
		instanceConstants(sample_rate);
		instanceResetUserInterface();
		instanceClear();
	}
	
	virtual mydsp* clone() {
		return new mydsp(*this);
	}
	
	virtual int getSampleRate() {
		return fSampleRate;
	}
	
	virtual void buildUserInterface(UI* ui_interface) {
		ui_interface->openVerticalBox("DeMoD LoFi Keys MkII");
		ui_interface->declare(0, "1", "");
		ui_interface->openVerticalBox("Piano");
		ui_interface->declare(&fHslider3, "0", "");
		ui_interface->declare(&fHslider3, "scale", "log");
		ui_interface->declare(&fHslider3, "unit", "s");
		ui_interface->addHorizontalSlider("Attack", &fHslider3, FAUSTFLOAT(0.003f), FAUSTFLOAT(0.001f), FAUSTFLOAT(0.2f), FAUSTFLOAT(0.001f));
		ui_interface->declare(&fHslider7, "1", "");
		ui_interface->declare(&fHslider7, "scale", "log");
		ui_interface->declare(&fHslider7, "unit", "s");
		ui_interface->addHorizontalSlider("Ring", &fHslider7, FAUSTFLOAT(1.6f), FAUSTFLOAT(0.15f), FAUSTFLOAT(6.0f), FAUSTFLOAT(0.001f));
		ui_interface->declare(&fHslider4, "2", "");
		ui_interface->declare(&fHslider4, "scale", "log");
		ui_interface->declare(&fHslider4, "unit", "s");
		ui_interface->addHorizontalSlider("Release", &fHslider4, FAUSTFLOAT(0.3f), FAUSTFLOAT(0.02f), FAUSTFLOAT(3.0f), FAUSTFLOAT(0.001f));
		ui_interface->declare(&fHslider10, "3", "");
		ui_interface->addHorizontalSlider("Color", &fHslider10, FAUSTFLOAT(0.55f), FAUSTFLOAT(0.0f), FAUSTFLOAT(1.0f), FAUSTFLOAT(0.001f));
		ui_interface->declare(&fHslider8, "4", "");
		ui_interface->addHorizontalSlider("Tine", &fHslider8, FAUSTFLOAT(0.4f), FAUSTFLOAT(0.0f), FAUSTFLOAT(1.0f), FAUSTFLOAT(0.001f));
		ui_interface->declare(&fHslider2, "5", "");
		ui_interface->addHorizontalSlider("Growl", &fHslider2, FAUSTFLOAT(0.35f), FAUSTFLOAT(0.0f), FAUSTFLOAT(1.0f), FAUSTFLOAT(0.001f));
		ui_interface->declare(&fHslider9, "6", "");
		ui_interface->declare(&fHslider9, "unit", "cent");
		ui_interface->addHorizontalSlider("Detune", &fHslider9, FAUSTFLOAT(5.0f), FAUSTFLOAT(0.0f), FAUSTFLOAT(25.0f), FAUSTFLOAT(0.01f));
		ui_interface->declare(&fHslider6, "7", "");
		ui_interface->declare(&fHslider6, "unit", "cent");
		ui_interface->addHorizontalSlider("Drift", &fHslider6, FAUSTFLOAT(3.0f), FAUSTFLOAT(0.0f), FAUSTFLOAT(3e+01f), FAUSTFLOAT(0.01f));
		ui_interface->declare(&fHslider0, "8", "");
		ui_interface->addHorizontalSlider("Mechanics", &fHslider0, FAUSTFLOAT(0.25f), FAUSTFLOAT(0.0f), FAUSTFLOAT(1.0f), FAUSTFLOAT(0.001f));
		ui_interface->closeBox();
		ui_interface->declare(&fHslider5, "unit", "Hz");
		ui_interface->addHorizontalSlider("freq", &fHslider5, FAUSTFLOAT(2.2e+02f), FAUSTFLOAT(2e+01f), FAUSTFLOAT(8e+03f), FAUSTFLOAT(0.001f));
		ui_interface->addHorizontalSlider("gain", &fHslider1, FAUSTFLOAT(0.8f), FAUSTFLOAT(0.0f), FAUSTFLOAT(1.0f), FAUSTFLOAT(0.001f));
		ui_interface->addButton("gate", &fButton0);
		ui_interface->closeBox();
	}
	
	virtual void compute(int count, FAUSTFLOAT** RESTRICT inputs, FAUSTFLOAT** RESTRICT outputs) {
		FAUSTFLOAT* output0 = outputs[0];
		float fSlow0 = static_cast<float>(fButton0);
		int iSlow1 = fSlow0 == 0.0f;
		float fSlow2 = fConst27 * static_cast<float>(fHslider0);
		float fSlow3 = static_cast<float>(fHslider1);
		float fSlow4 = 0.6f * fSlow3 + 0.4f;
		float fSlow5 = fConst27 * static_cast<float>(fHslider2);
		float fSlow6 = 1.5f * fSlow3;
		float fSlow7 = fConst27 * static_cast<float>(fHslider3);
		float fSlow8 = fConst27 * static_cast<float>(fHslider4);
		float fSlow9 = static_cast<float>(fHslider5);
		float fSlow10 = 0.0193f * fSlow9;
		float fSlow11 = 0.4f * (2.0f * (fSlow10 + (0.137f - std::floor(fSlow10 + 0.137f))) + -1.0f);
		float fSlow12 = fConst27 * static_cast<float>(fHslider6);
		float fSlow13 = 2.2e+02f / fSlow9;
		float fSlow14 = fConst27 * static_cast<float>(fHslider7);
		float fSlow15 = 5.5879353e-11f * (fSlow3 + 1.0f);
		float fSlow16 = 1.0f / std::tan(fConst32 * (6e+03f * fSlow3 + 2.5e+03f));
		float fSlow17 = 1.0f - fSlow16;
		float fSlow18 = 1.0f / (fSlow16 + 1.0f);
		float fSlow19 = 13.7f * fSlow9;
		float fSlow20 = fConst27 * static_cast<float>(fHslider8);
		float fSlow21 = 0.7f * fSlow3 + 0.3f;
		float fSlow22 = 4.2f * fSlow9;
		float fSlow23 = 3.0f * fSlow9;
		float fSlow24 = 2.0f * fSlow9;
		float fSlow25 = fConst27 * static_cast<float>(fHslider9);
		float fSlow26 = fConst4 * fSlow9;
		float fSlow27 = fConst27 * static_cast<float>(fHslider10);
		float fSlow28 = 3.5f * (0.4f * fSlow3 + 0.6f);
		for (int i0 = 0; i0 < count; i0 = i0 + 1) {
			fVec0[0] = fSlow0;
			iRec1[0] = iSlow1 * (iRec1[1] + 1);
			float fTemp0 = static_cast<float>(iRec1[0]);
			fRec2[0] = fSlow0 + fRec2[1] * static_cast<float>(fVec0[1] >= fSlow0);
			float fTemp1 = 1.0f - fRec2[0];
			int iTemp2 = 1103515245 * (iRec3[1] + 12345);
			int iTemp3 = 1103515245 * (iTemp2 + 12345);
			int iTemp4 = 1103515245 * (iTemp3 + 12345);
			iRec3[0] = 1103515245 * (iTemp4 + 12345);
			int iRec4 = iTemp4;
			int iRec5 = iTemp3;
			int iRec6 = iTemp2;
			fRec0[0] = 4.656613e-10f * static_cast<float>(iRec5) * std::max<float>(0.0f, std::min<float>(fRec2[0], std::max<float>(fConst22 * fTemp1 + 1.0f, 0.0f)) * (1.0f - fConst22 * fTemp0)) - fConst21 * (fConst19 * fRec0[1] + fConst18 * fRec0[2] + fConst17 * fRec0[3] + fConst13 * fRec0[4]);
			fRec8[0] = 0.995f * fRec8[1] + static_cast<float>(fVec0[1] > fSlow0);
			float fTemp5 = fRec8[0] * static_cast<float>(iRec6);
			fVec1[0] = fTemp5;
			fRec7[0] = fConst26 * (4.656613e-10f * (fTemp5 + fVec1[1]) - fConst25 * fRec7[1]);
			fRec9[0] = fSlow2 + fConst28 * fRec9[1];
			fRec10[0] = fSlow5 + fConst28 * fRec10[1];
			float fTemp6 = fSlow6 * fRec10[0] + 1.0f;
			fRec11[0] = fSlow7 + fConst28 * fRec11[1];
			float fTemp7 = std::max<float>(1.0f, fConst0 * fRec11[0]);
			float fTemp8 = fRec2[0] / fTemp7;
			fRec12[0] = fSlow8 + fConst28 * fRec12[1];
			float fTemp9 = 1.0f - fTemp0 / std::max<float>(1.0f, fConst0 * fRec12[0]);
			float fTemp10 = std::max<float>(-3.0f, std::min<float>(3.0f, 0.08f * fTemp6));
			float fTemp11 = mydsp_faustpower2_f(fTemp10);
			float fTemp12 = fSlow0 - fVec0[1];
			float fTemp13 = fTemp12 * static_cast<float>(fTemp12 > 0.0f);
			fVec2[0] = fTemp13;
			fRec14[0] = ((static_cast<int>(fTemp13)) ? 4.656613e-10f * static_cast<float>(iRec3[0]) : fRec14[1]);
			fRec15[0] = fSlow12 + fConst28 * fRec15[1];
			float fTemp14 = std::pow(2.0f, 0.00083333335f * fRec15[0] * (fSlow11 + 0.6f * fRec14[0]));
			fRec16[0] = fSlow14 + fConst28 * fRec16[1];
			float fTemp15 = fRec16[0] * std::min<float>(2.0f, std::max<float>(0.4f, std::sqrt(fSlow13 / fTemp14)));
			float fTemp16 = std::pow(0.001f, fConst4 / std::max<float>(0.02f, fTemp15));
			fRec17[0] = -(fSlow18 * (fSlow17 * fRec17[1] - (fTemp13 + fVec2[1])));
			float fTemp17 = 0.85f * fRec17[0] + fSlow15 * static_cast<float>(iRec4) * std::max<float>(0.0f, std::min<float>(fRec2[0], std::max<float>(fConst31 * fTemp1 + 1.0f, 0.0f)) * (1.0f - fConst31 * fTemp0));
			fRec13[0] = fTemp17 + 2.0f * fRec13[1] * fTemp16 * std::cos(fConst30 * std::min<float>(fSlow9 * fTemp14, fConst29)) - fRec13[2] * mydsp_faustpower2_f(fTemp16);
			float fTemp18 = std::pow(0.001f, fConst4 / std::max<float>(0.02f, 0.12f * fTemp15));
			fRec18[0] = fTemp17 + 2.0f * fRec18[1] * fTemp18 * std::cos(fConst30 * std::min<float>(fSlow19 * fTemp14, fConst29)) - fRec18[2] * mydsp_faustpower2_f(fTemp18);
			fRec19[0] = fSlow20 + fConst28 * fRec19[1];
			float fTemp19 = std::pow(0.001f, fConst4 / std::max<float>(0.02f, 0.3f * fTemp15));
			fRec20[0] = fTemp17 + 2.0f * fRec20[1] * fTemp19 * std::cos(fConst30 * std::min<float>(fSlow22 * fTemp14, fConst29)) - fRec20[2] * mydsp_faustpower2_f(fTemp19);
			float fTemp20 = std::pow(0.001f, fConst4 / std::max<float>(0.02f, 0.5f * fTemp15));
			fRec21[0] = fTemp17 + 2.0f * fRec21[1] * fTemp20 * std::cos(fConst30 * std::min<float>(fSlow23 * fTemp14, fConst29)) - fRec21[2] * mydsp_faustpower2_f(fTemp20);
			float fTemp21 = std::pow(0.001f, fConst4 / std::max<float>(0.02f, 0.7f * fTemp15));
			fRec22[0] = fTemp17 + 2.0f * fRec22[1] * fTemp21 * std::cos(fConst30 * std::min<float>(fSlow24 * fTemp14, fConst29)) - fRec22[2] * mydsp_faustpower2_f(fTemp21);
			fRec24[0] = fSlow25 + fConst28 * fRec24[1];
			fRec23[0] = fRec23[1] + fSlow26 * fTemp14 * std::pow(2.0f, 0.00083333335f * fRec24[0]) - std::floor(fRec23[1]);
			float fTemp22 = 6.2831855f * fRec23[0];
			fRec25[0] = fSlow27 + fConst28 * fRec25[1];
			float fTemp23 = fRec25[0] * std::max<float>(0.0f, std::min<float>(fRec2[0], std::max<float>(fConst35 * fTemp1 + 1.0f, 0.1f)) * (1.0f - fConst34 * fTemp0));
			fRec26[0] = fRec26[1] + fSlow26 * fTemp14 - std::floor(fRec26[1]);
			float fTemp24 = 6.2831855f * fRec26[0];
			float fTemp25 = std::max<float>(-3.0f, std::min<float>(3.0f, fTemp6 * (0.3f * (0.5f * (std::sin(fTemp24 + fSlow28 * fTemp23 * std::sin(fTemp24)) + std::sin(fTemp22 + fSlow28 * fTemp23 * std::sin(fTemp22))) * std::max<float>(0.0f, std::min<float>(fTemp8, std::max<float>((fTemp7 - fRec2[0]) / std::max<float>(1.0f, fConst33 * fRec16[0]) + 1.0f, 0.0f)) * fTemp9) + 0.9f * (fRec13[0] + 0.5f * (fRec22[0] - fRec22[2]) + 0.32f * (fRec21[0] - fRec21[2]) + 0.22f * (fRec20[0] - fRec20[2]) + fSlow21 * fRec19[0] * (fRec18[0] - fRec18[2]) - fRec13[2])) + 0.08f)));
			float fTemp26 = mydsp_faustpower2_f(fTemp25);
			output0[i0] = static_cast<FAUSTFLOAT>(0.3f * (fSlow3 * ((fTemp25 * (fTemp26 + 27.0f) / (9.0f * fTemp26 + 27.0f) - fTemp10 * (fTemp11 + 27.0f) / (9.0f * fTemp11 + 27.0f)) * std::max<float>(0.0f, fTemp9 * std::min<float>(fTemp8, 1.0f)) / fTemp6) + fSlow4 * fRec9[0] * (0.6f * fRec7[0] + fConst23 * (4.0f * fRec0[0] - 8.0f * fRec0[2] + 4.0f * fRec0[4]))));
			fVec0[1] = fVec0[0];
			iRec1[1] = iRec1[0];
			fRec2[1] = fRec2[0];
			iRec3[1] = iRec3[0];
			for (int j0 = 4; j0 > 0; j0 = j0 - 1) {
				fRec0[j0] = fRec0[j0 - 1];
			}
			fRec8[1] = fRec8[0];
			fVec1[1] = fVec1[0];
			fRec7[1] = fRec7[0];
			fRec9[1] = fRec9[0];
			fRec10[1] = fRec10[0];
			fRec11[1] = fRec11[0];
			fRec12[1] = fRec12[0];
			fVec2[1] = fVec2[0];
			fRec14[1] = fRec14[0];
			fRec15[1] = fRec15[0];
			fRec16[1] = fRec16[0];
			fRec17[1] = fRec17[0];
			fRec13[2] = fRec13[1];
			fRec13[1] = fRec13[0];
			fRec18[2] = fRec18[1];
			fRec18[1] = fRec18[0];
			fRec19[1] = fRec19[0];
			fRec20[2] = fRec20[1];
			fRec20[1] = fRec20[0];
			fRec21[2] = fRec21[1];
			fRec21[1] = fRec21[0];
			fRec22[2] = fRec22[1];
			fRec22[1] = fRec22[0];
			fRec24[1] = fRec24[0];
			fRec23[1] = fRec23[0];
			fRec25[1] = fRec25[0];
			fRec26[1] = fRec26[0];
		}
	}

};

/* ── Parameter-map UI ──────────────────────────────────────────────────── */
/*
 * Walks the DSP's UI tree and collects every control as a (label, ptr) pair.
 * Label matching strips group prefixes so callers can use bare names like
 * "freq", "gate", "gain", "Cutoff", etc.
 */

struct Param {
    std::string  full_label;   /* e.g. "h:Oscillator/[1] Freq" */
    std::string  short_label;  /* basename after last '/', brackets stripped */
    FAUSTFLOAT*  zone;
    FAUSTFLOAT   init, lo, hi, step;
    bool         is_button;
};

static std::string strip_label(const std::string& raw) {
    /* Take the last path component and strip [N] ordering prefixes. */
    size_t slash = raw.rfind('/');
    std::string base = (slash == std::string::npos) ? raw : raw.substr(slash + 1);
    /* Remove "[N] " prefix */
    if (!base.empty() && base[0] == '[') {
        size_t close = base.find(']');
        if (close != std::string::npos && close + 2 <= base.size())
            base = base.substr(close + 2);
    }
    /* Strip [unit:...], [style:...] metadata annotations */
    size_t meta = base.find(" [");
    if (meta != std::string::npos) base = base.substr(0, meta);
    /* Lowercase */
    std::transform(base.begin(), base.end(), base.begin(), ::tolower);
    return base;
}

class ParamUI : public UI {
public:
    std::vector<Param> params;
    std::string        path_prefix;

    void push(const char* label) {
        if (!path_prefix.empty()) path_prefix += "/";
        path_prefix += label;
    }
    void pop() {
        size_t s = path_prefix.rfind('/');
        path_prefix = (s == std::string::npos) ? "" : path_prefix.substr(0, s);
    }

    void openTabBox(const char* l)        override { push(l); }
    void openHorizontalBox(const char* l) override { push(l); }
    void openVerticalBox(const char* l)   override { push(l); }
    void closeBox()                       override { pop(); }

    void addControl(const char* label, FAUSTFLOAT* zone,
                    FAUSTFLOAT init, FAUSTFLOAT lo, FAUSTFLOAT hi,
                    FAUSTFLOAT step, bool is_button) {
        std::string full = path_prefix.empty()
            ? label
            : path_prefix + "/" + label;
        Param p;
        p.full_label  = full;
        p.short_label = strip_label(full);
        p.zone        = zone;
        p.init = init; p.lo = lo; p.hi = hi; p.step = step;
        p.is_button   = is_button;
        params.push_back(p);
    }

    void addButton(const char* l, FAUSTFLOAT* z) override
        { addControl(l, z, 0, 0, 1, 1, true); }
    void addCheckButton(const char* l, FAUSTFLOAT* z) override
        { addControl(l, z, 0, 0, 1, 1, false); }
    void addVerticalSlider(const char* l, FAUSTFLOAT* z,
        FAUSTFLOAT d, FAUSTFLOAT a, FAUSTFLOAT b, FAUSTFLOAT s) override
        { addControl(l, z, d, a, b, s, false); }
    void addHorizontalSlider(const char* l, FAUSTFLOAT* z,
        FAUSTFLOAT d, FAUSTFLOAT a, FAUSTFLOAT b, FAUSTFLOAT s) override
        { addControl(l, z, d, a, b, s, false); }
    void addNumEntry(const char* l, FAUSTFLOAT* z,
        FAUSTFLOAT d, FAUSTFLOAT a, FAUSTFLOAT b, FAUSTFLOAT s) override
        { addControl(l, z, d, a, b, s, false); }
};

/* ── C-API handle ──────────────────────────────────────────────────────── */

struct SynthHandle {
    mydsp*   dsp;
    ParamUI* ui;

    /* per-compute scratch buffers */
    int          buf_size;
    FAUSTFLOAT** in_bufs;
    FAUSTFLOAT** out_bufs;
    int          n_in, n_out;
};

static void alloc_io(SynthHandle* h, int buf_size) {
    h->buf_size = buf_size;
    h->n_in     = h->dsp->getNumInputs();
    h->n_out    = h->dsp->getNumOutputs();

    h->in_bufs  = (FAUSTFLOAT**)malloc(sizeof(FAUSTFLOAT*) * std::max(h->n_in,  1));
    h->out_bufs = (FAUSTFLOAT**)malloc(sizeof(FAUSTFLOAT*) * std::max(h->n_out, 1));

    for (int i = 0; i < h->n_in;  i++)
        h->in_bufs[i]  = (FAUSTFLOAT*)calloc(buf_size, sizeof(FAUSTFLOAT));
    for (int i = 0; i < h->n_out; i++)
        h->out_bufs[i] = (FAUSTFLOAT*)calloc(buf_size, sizeof(FAUSTFLOAT));
}

static void free_io(SynthHandle* h) {
    for (int i = 0; i < h->n_in;  i++) free(h->in_bufs[i]);
    for (int i = 0; i < h->n_out; i++) free(h->out_bufs[i]);
    free(h->in_bufs);
    free(h->out_bufs);
}

/* ── Public C API ──────────────────────────────────────────────────────── */

extern "C" {

void* synth_new(int sample_rate) {
    SynthHandle* h = new SynthHandle();
    h->dsp = new mydsp();
    h->ui  = new ParamUI();
    h->dsp->init(sample_rate);
    h->dsp->buildUserInterface(h->ui);
    alloc_io(h, BUFFER_SIZE);
    return (void*)h;
}

void synth_delete(void* handle) {
    SynthHandle* h = (SynthHandle*)handle;
    free_io(h);
    delete h->dsp;
    delete h->ui;
    delete h;
}

/* Reset DSP state (clear delay lines, envelopes, etc.) */
void synth_reset(void* handle) {
    SynthHandle* h = (SynthHandle*)handle;
    h->dsp->instanceClear();
    h->dsp->instanceResetUserInterface();
}

int synth_num_inputs(void* handle)  { return ((SynthHandle*)handle)->dsp->getNumInputs();  }
int synth_num_outputs(void* handle) { return ((SynthHandle*)handle)->dsp->getNumOutputs(); }

/* ── Parameter access ────────────────────────────────────────────────── */

/*
 * Returns number of registered parameters.
 */
int synth_num_params(void* handle) {
    return (int)((SynthHandle*)handle)->ui->params.size();
}

/*
 * Write short (lowercase, no path) label of param[index] into buf.
 * Returns 0 on success, -1 if index out of range.
 */
int synth_param_label(void* handle, int index, char* buf, int buf_len) {
    SynthHandle* h = (SynthHandle*)handle;
    if (index < 0 || index >= (int)h->ui->params.size()) return -1;
    const std::string& s = h->ui->params[index].short_label;
    strncpy(buf, s.c_str(), buf_len - 1);
    buf[buf_len - 1] = '\0';
    return 0;
}

int synth_param_full_label(void* handle, int index, char* buf, int buf_len) {
    SynthHandle* h = (SynthHandle*)handle;
    if (index < 0 || index >= (int)h->ui->params.size()) return -1;
    const std::string& s = h->ui->params[index].full_label;
    strncpy(buf, s.c_str(), buf_len - 1);
    buf[buf_len - 1] = '\0';
    return 0;
}

/* get/set by short label (case-insensitive, first match wins) */
int synth_set_param(void* handle, const char* label, float value) {
    SynthHandle* h = (SynthHandle*)handle;
    std::string key(label);
    std::transform(key.begin(), key.end(), key.begin(), ::tolower);
    for (auto& p : h->ui->params) {
        if (p.short_label == key) {
            float clamped = std::max((float)p.lo, std::min((float)p.hi, value));
            *p.zone = (FAUSTFLOAT)clamped;
            return 0;
        }
    }
    return -1;   /* not found */
}

float synth_get_param(void* handle, const char* label) {
    SynthHandle* h = (SynthHandle*)handle;
    std::string key(label);
    std::transform(key.begin(), key.end(), key.begin(), ::tolower);
    for (auto& p : h->ui->params) {
        if (p.short_label == key)
            return (float)*p.zone;
    }
    return 0.0f;
}

/* get/set by index */
int   synth_set_param_idx(void* handle, int idx, float v) {
    SynthHandle* h = (SynthHandle*)handle;
    if (idx < 0 || idx >= (int)h->ui->params.size()) return -1;
    auto& p = h->ui->params[idx];
    *p.zone = (FAUSTFLOAT)std::max((float)p.lo, std::min((float)p.hi, v));
    return 0;
}
float synth_get_param_idx(void* handle, int idx) {
    SynthHandle* h = (SynthHandle*)handle;
    if (idx < 0 || idx >= (int)h->ui->params.size()) return 0.0f;
    return (float)*h->ui->params[idx].zone;
}
float synth_param_default(void* handle, int idx) {
    SynthHandle* h = (SynthHandle*)handle;
    if (idx < 0 || idx >= (int)h->ui->params.size()) return 0.0f;
    return (float)h->ui->params[idx].init;
}
float synth_param_min(void* handle, int idx) {
    SynthHandle* h = (SynthHandle*)handle;
    if (idx < 0 || idx >= (int)h->ui->params.size()) return 0.0f;
    return (float)h->ui->params[idx].lo;
}
float synth_param_max(void* handle, int idx) {
    SynthHandle* h = (SynthHandle*)handle;
    if (idx < 0 || idx >= (int)h->ui->params.size()) return 0.0f;
    return (float)h->ui->params[idx].hi;
}

/* ── Audio compute ───────────────────────────────────────────────────── */

/*
 * Render `n_frames` of audio.
 * out_L / out_R: caller-allocated float arrays of length n_frames.
 * For mono DSPs, out_R is filled with the same signal.
 * For DSPs with > 2 outputs, only channels 0 and 1 are exported.
 * For DSPs with inputs, in_buf (optional) provides the first input channel
 * (pass NULL for synth-style no-input DSPs).
 */
void synth_compute(void* handle, int n_frames,
                   float* in_buf,
                   float* out_L, float* out_R) {
    SynthHandle* h = (SynthHandle*)handle;

    int processed = 0;
    while (processed < n_frames) {
        int chunk = std::min(n_frames - processed, h->buf_size);

        /* Fill input buffers */
        for (int ch = 0; ch < h->n_in; ch++) {
            if (in_buf)
                memcpy(h->in_bufs[ch], in_buf + processed,
                       chunk * sizeof(FAUSTFLOAT));
            else
                memset(h->in_bufs[ch], 0, chunk * sizeof(FAUSTFLOAT));
        }

        h->dsp->compute(chunk, h->in_bufs, h->out_bufs);

        /* Copy outputs */
        if (h->n_out >= 2) {
            for (int i = 0; i < chunk; i++) {
                out_L[processed + i] = h->out_bufs[0][i];
                out_R[processed + i] = h->out_bufs[1][i];
            }
        } else if (h->n_out == 1) {
            for (int i = 0; i < chunk; i++) {
                out_L[processed + i] = h->out_bufs[0][i];
                out_R[processed + i] = h->out_bufs[0][i];
            }
        }
        processed += chunk;
    }
}

} /* extern "C" */

#endif
