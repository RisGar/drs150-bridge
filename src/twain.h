/* Minimal TWAIN 1.9 subset, 64-bit (Apple TWAIN.framework 1.9.5 ABI) */
#ifndef TWAIN_MIN_H
#define TWAIN_MIN_H
#include <stdint.h>
typedef uint8_t TW_UINT8;
typedef int8_t TW_INT8;
typedef uint16_t TW_UINT16;
typedef int16_t TW_INT16;
typedef uint32_t TW_UINT32;
typedef int32_t TW_INT32;
typedef unsigned char TW_BOOL;
typedef char TW_STR32[34];
#define TW_STR255LEN 256
typedef char TW_STR255[TW_STR255LEN];

typedef struct {
  TW_UINT16 MajorNum, MinorNum, Language, Country;
  TW_UINT8 Info[34];
} TW_VERSION;
typedef struct {
  TW_UINT32 Id; /* 4 bytes in twain.h -- probe switches if needed */
  TW_VERSION Version;
  TW_UINT16 ProtocolMajor, ProtocolMinor;
  TW_UINT32 SupportedGroups;
  TW_STR32 Manufacturer, ProductFamily, ProductName;
} TW_IDENTITY;

typedef struct {
  TW_INT32 Whole;
  TW_UINT32 Frac;
} TW_FIX32;
/* Canon/macOS TWAIN 1.9.5 uses a pointer-sized Id (verified against driver) */
typedef struct {
  void *Id;
  TW_VERSION Version;
  TW_UINT16 ProtocolMajor, ProtocolMinor;
  TW_UINT32 SupportedGroups;
  TW_STR32 Manufacturer, ProductFamily, ProductName;
} TW_IDENTITY8;

typedef struct {
  TW_UINT16 ItemType;
  TW_UINT32 Item;
} TW_ONEVALUE;
typedef struct {
  TW_UINT16 ItemType;
  TW_UINT32 NumItems, CurrentIndex, DefaultIndex;
  TW_UINT8 ItemList[4];
} TW_ENUMERATION;
typedef struct {
  TW_UINT16 ItemType;
  TW_UINT32 MinValue, MaxValue, StepSize, DefaultValue, CurrentValue;
} TW_RANGE;
typedef struct {
  TW_UINT16 Cap, ConType;
  void *hContainer;
} TW_CAPABILITY;
typedef struct {
  TW_UINT16 ShowUI, ModalUI;
  void *hParent;
} TW_USERINTERFACE;
typedef struct {
  TW_STR255 FileName;
  TW_UINT16 Format;
  TW_INT16 VRefNum;
} TW_SETUPFILEXFER;
typedef struct {
  TW_UINT16 Count;
  union {
    TW_UINT32 EOJ;
    void *hMem;
  } JobControl;
} TW_PENDINGXFERS;
typedef struct {
  void *pEvent;
  TW_UINT16 TWMessage;
} TW_EVENT;
typedef struct {
  TW_UINT16 ConditionCode, Reserved;
} TW_STATUS;
typedef struct {
  TW_INT32 ImageWidth, ImageLength;
} TW_DUMMYIMAGEINFO; /* unused */
typedef struct {
  TW_UINT32 Size;
  void *DSM_Entry;
  void *DSM_MemAllocate;
  void *DSM_MemFree;
  void *DSM_MemLock;
  void *DSM_MemUnlock;
} TW_ENTRYPOINT;

/* DG */
#define DG_CONTROL 1
#define DG_IMAGE 2
/* DAT */
#define DAT_NULL 0
#define DAT_CAPABILITY 1
#define DAT_EVENT 2
#define DAT_IDENTITY 3
#define DAT_PARENT 4
#define DAT_PENDINGXFERS 5
#define DAT_SETUPMEMXFER 6
#define DAT_SETUPFILEXFER 7
#define DAT_STATUS 8
#define DAT_USERINTERFACE 9
#define DAT_XFERGROUP 0x000a
#define DAT_CUSTOMDSDATA 0x000c
#define DAT_DEVICEEVENT 0x000d
#define DAT_FILESYSTEM 0x000e
#define DAT_PASSTHRU 0x000f
#define DAT_CALLBACK 0x0010
#define DAT_SETUPFILEXFER2 0x0301
#define DAT_IMAGEINFO 0x0101
#define DAT_IMAGELAYOUT 0x0102
#define DAT_IMAGEMEMXFER 0x0103
#define DAT_IMAGENATIVEXFER 0x0104
#define DAT_IMAGEFILEXFER 0x0105
#define DAT_JPEGCOMPRESSION 0x0109
#define DAT_PALETTE8 0x010a
#define DAT_EXTIMAGEINFO 0x010b
/* MSG */
#define MSG_NULL 0
#define MSG_GET 1
#define MSG_GETCURRENT 2
#define MSG_GETDEFAULT 3
#define MSG_GETFIRST 4
#define MSG_GETNEXT 5
#define MSG_SET 6
#define MSG_RESET 7
#define MSG_QUERYSUPPORT 8
#define MSG_OPENDS 0x0401
#define MSG_CLOSEDS 0x0402
#define MSG_USERSELECT 0x0403
#define MSG_DISABLEDS 0x0501
#define MSG_ENABLEDS 0x0502
#define MSG_ENABLEDSUIONLY 0x0503
#define MSG_PROCESSEVENT 0x0601
#define MSG_STOPFEEDER 0x0702
#define MSG_REGISTER_CALLBACK 0x0902
#define MSG_INVOKE_CALLBACK 0x0903
#define MSG_XFERREADY 0x0101
#define MSG_CLOSEDSREQ 0x0102
#define MSG_CLOSEDSOK 0x0103
#define MSG_DEVICEEVENT 0x0104
#define MSG_OPENDSM 0x0301
#define MSG_CLOSEDSM 0x0302
#define MSG_ENDXFER 0x0701
/* containers */
#define TWON_ARRAY 3
#define TWON_ENUMERATION 4
#define TWON_ONEVALUE 5
#define TWON_RANGE 6
/* types */
#define TWTY_INT8 0
#define TWTY_INT16 1
#define TWTY_INT32 2
#define TWTY_UINT8 3
#define TWTY_UINT16 4
#define TWTY_UINT32 5
#define TWTY_BOOL 6
#define TWTY_FIX32 7
#define TWTY_STR32 9
#define TWTY_STR255 12
/* return codes */
#define TWRC_SUCCESS 0
#define TWRC_FAILURE 1
#define TWRC_CHECKSTATUS 2
#define TWRC_CANCEL 3
#define TWRC_DSEVENT 4
#define TWRC_NOTDSEVENT 5
#define TWRC_XFERDONE 6
#define TWRC_ENDOFLIST 7
#define TWRC_INFO 8
/* caps */
#define ICAP_COMPRESSION 0x0100
#define ICAP_PIXELTYPE 0x0101
#define ICAP_UNITS 0x0102
#define ICAP_XFERMECH 0x0103
#define ICAP_XRESOLUTION 0x1118
#define ICAP_YRESOLUTION 0x1119
#define ICAP_IMAGEFILEFORMAT 0x110c
#define ICAP_PIXELFLAVOR 0x111f
#define ICAP_SUPPORTEDSIZES 0x1122
#define ICAP_BITDEPTH 0x112b
#define ICAP_AUTODISCARDBLANKPAGES 0x1154
#define CAP_FEEDERENABLED 0x1002
#define CAP_FEEDERLOADED 0x1003
#define CAP_AUTOFEED 0x1007
#define CAP_AUTOSCAN 0x1010
#define CAP_DUPLEX 0x1012
#define CAP_DUPLEXENABLED 0x1013
#define CAP_SUPPORTEDCAPS 0x1005
#define CAP_UICONTROLLABLE 0x100e
#define CAP_DEVICEONLINE 0x100f
#define CAP_INDICATORS 0x100b
#define CAP_JOBCONTROL 0x1017
#define CAP_ENDORSER 0x1016
#define CAP_XFERCOUNT 0x0001
/* values */
#define TWPT_BW 0
#define TWPT_GRAY 1
#define TWPT_RGB 2
#define TWSX_NATIVE 0
#define TWSX_FILE 1
#define TWSX_MEMORY 2
#define TWFF_TIFF 0
#define TWFF_PICT 1
#define TWFF_BMP 2
#define TWFF_JFIF 4
#define TWFF_TIFFMULTI 6
#define TWFF_PNG 7
#define TWFF_PDF 10
#define TWCC_SUCCESS 0
#endif
