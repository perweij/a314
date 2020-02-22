#include <exec/types.h>
#include <exec/execbase.h>
#include <exec/devices.h>
#include <exec/errors.h>
#include <exec/ports.h>
#include <libraries/dos.h>
#include <proto/exec.h>

#include "device.h"
#include "a314.h"
#include "startup.h"
#include "fix_mem_region.h"

char device_name[] = A314_NAME;
char id_string[] = A314_NAME " 1.0 (25 Aug 2018)";

struct ExecBase *SysBase;
BPTR saved_seg_list;
BOOL running = FALSE;

struct Library *init_device(__reg("a6") struct ExecBase *sys_base, __reg("a0") BPTR seg_list, __reg("d0") struct Library *dev)
{
	SysBase = *(struct ExecBase **)4;
	saved_seg_list = seg_list;

	// Vi anropas från InitResident i initializers.asm.
	// Innan vi har kommit hit så har MakeLibrary körts.

	dev->lib_Node.ln_Type = NT_DEVICE;
	dev->lib_Node.ln_Name = device_name;
	dev->lib_Flags = LIBF_SUMUSED | LIBF_CHANGED;
	dev->lib_Version = 1;
	dev->lib_Revision = 0;
	dev->lib_IdString = (APTR)id_string;

	// Efter vi returnerar så körs AddDevice.
	return dev;
}

BPTR expunge(__reg("a6") struct Library *dev)
{
	// Det finns inget sätt att ladda ur a314.device för närvarande.
	if (TRUE) //dev->lib_OpenCnt != 0)
	{
		dev->lib_Flags |= LIBF_DELEXP;
		return 0;
	}

	/*
	BPTR seg_list = saved_seg_list;
	Remove(&dev->lib_Node);
	FreeMem((char *)dev - dev->lib_NegSize, dev->lib_NegSize + dev->lib_PosSize);
	return seg_list;
	*/
}

void open(__reg("a6") struct Library *dev, __reg("a1") struct A314_IORequest *ior, __reg("d0") ULONG unitnum, __reg("d1") ULONG flags)
{
	dev->lib_OpenCnt++;

	if (dev->lib_OpenCnt == 1 && !running)
	{
		if (!task_start())
		{
			ior->a314_Request.io_Error = IOERR_OPENFAIL;
			ior->a314_Request.io_Message.mn_Node.ln_Type = NT_REPLYMSG;
			dev->lib_OpenCnt--;
			return;
		}
		running = TRUE;
	}

	ior->a314_Request.io_Error = 0;
	ior->a314_Request.io_Message.mn_Node.ln_Type = NT_REPLYMSG;
}

BPTR close(__reg("a6") struct Library *dev, __reg("a1") struct A314_IORequest *ior)
{
	ior->a314_Request.io_Device = NULL;
	ior->a314_Request.io_Unit = NULL;

	dev->lib_OpenCnt--;

	if (dev->lib_OpenCnt == 0 && (dev->lib_Flags & LIBF_DELEXP))
		return expunge(dev);

	return 0;
}

void begin_io(__reg("a6") struct Library *dev, __reg("a1") struct A314_IORequest *ior)
{
	PutMsg(&task_mp, (struct Message *)ior);
	ior->a314_Request.io_Flags &= ~IOF_QUICK;
}

ULONG abort_io(__reg("a6") struct Library *dev, __reg("a1") struct A314_IORequest *ior)
{
	// No-operation.
	return IOERR_NOCMD;
}

ULONG device_vectors[] =
{
	(ULONG)open,
	(ULONG)close,
	(ULONG)expunge,
	0,
	(ULONG)begin_io,
	(ULONG)abort_io,
	(ULONG)translate_address_a314,
	-1,
};

ULONG auto_init_tables[] =
{
	sizeof(struct Library),
	(ULONG)device_vectors,
	0,
	(ULONG)init_device,
};
