#ifndef DEMOD_FAUST_GLUE_H
#define DEMOD_FAUST_GLUE_H

#ifdef __cplusplus
extern "C" {
#endif

#ifndef FAUSTFLOAT
#define FAUSTFLOAT float
#endif

#define DEMOD_FAUST_LABEL_GATE "gate"
#define DEMOD_FAUST_LABEL_FREQ "freq"
#define DEMOD_FAUST_LABEL_GAIN "gain"

typedef struct MetaGlue {
    void *metaInterface;
    void (*declare)(void *meta_interface, const char *key, const char *value);
} MetaGlue;

typedef struct UIGlue {
    void *uiInterface;
    void (*openTabBox)(void *ui_interface, const char *label);
    void (*openHorizontalBox)(void *ui_interface, const char *label);
    void (*openVerticalBox)(void *ui_interface, const char *label);
    void (*closeBox)(void *ui_interface);
    void (*addButton)(void *ui_interface, const char *label, FAUSTFLOAT *zone);
    void (*addCheckButton)(void *ui_interface, const char *label, FAUSTFLOAT *zone);
    void (*addVerticalSlider)(void *ui_interface, const char *label, FAUSTFLOAT *zone,
                              FAUSTFLOAT init, FAUSTFLOAT min, FAUSTFLOAT max, FAUSTFLOAT step);
    void (*addHorizontalSlider)(void *ui_interface, const char *label, FAUSTFLOAT *zone,
                                FAUSTFLOAT init, FAUSTFLOAT min, FAUSTFLOAT max, FAUSTFLOAT step);
    void (*addNumEntry)(void *ui_interface, const char *label, FAUSTFLOAT *zone,
                        FAUSTFLOAT init, FAUSTFLOAT min, FAUSTFLOAT max, FAUSTFLOAT step);
    void (*addHorizontalBargraph)(void *ui_interface, const char *label, FAUSTFLOAT *zone,
                                  FAUSTFLOAT min, FAUSTFLOAT max);
    void (*addVerticalBargraph)(void *ui_interface, const char *label, FAUSTFLOAT *zone,
                                FAUSTFLOAT min, FAUSTFLOAT max);
    void (*declare)(void *ui_interface, FAUSTFLOAT *zone, const char *key, const char *value);
} UIGlue;

#ifdef __cplusplus
}
#endif

#endif /* DEMOD_FAUST_GLUE_H */
