/*
Copyright (C) 1996-1997 Id Software, Inc.

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  

See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.

*/
// cd_mac.m

#include "quakedef.h"
#include "unixquake.h"
#include "macquake.h"

cvar_t bgmvolume = {"bgmvolume", "1", true};
cvar_t bgmtype = {"bgmtype", "cd", true};   // cd or none

static qboolean cdValid = false;
static qboolean	playing = false;
static qboolean	wasPlaying = false;
static qboolean	initialized = false;
static qboolean	enabled = false;
static qboolean playLooping = false;
static byte 	remap[100];
static byte		playTrack;
static byte		maxTrack;

/* ------------------------------------------------------------------------------------ */

typedef struct _AIFFChunkHeader {
    unsigned int chunkID;
    unsigned int chunkSize;
    unsigned int fileType;
} AIFFChunkHeader;

typedef struct _AIFFGenericChunk {
    unsigned int chunkID;
    unsigned int chunkSize;
} AIFFGenericChunk;

typedef struct _AIFFSSNDData {
    unsigned int offset;
    unsigned int blockSize;
} AIFFSSNDData;

typedef struct _AIFFInfo {
    FILE *file;
} AIFFInfo; 

AIFFInfo *AIFFOpen(NSString *path);
void AIFFClose(AIFFInfo *aiff);

/* ------------------------------------------------------------------------------------ */

NSMutableArray *cdTracks;

static float	old_cdvolume;

#define SAMPLES_PER_BUFFER (2*1024)

static AIFFInfo         *aiffInfo;
static short            *samples;

static AudioDeviceIOProcID ioprocid = NULL;
static OSStatus audioDeviceIOProc(AudioDeviceID inDevice,
                                  const AudioTimeStamp *inNow,
                                  const AudioBufferList *inInputData,
                                  const AudioTimeStamp *inInputTime,
                                  AudioBufferList *outOutputData,
                                  const AudioTimeStamp *inOutputTime,
                                  void *inClientData);

/*
====================
AIFF-C read routines
====================
*/

AIFFInfo *AIFFOpen(NSString *path)
{
    const char *pathStr;
    AIFFInfo *aiff;
    FILE *file;
    AIFFChunkHeader chunkHeader;
    AIFFGenericChunk chunk;
    AIFFSSNDData ssndData;
    
    pathStr = [path fileSystemRepresentation];
    file = fopen(pathStr, "r");
    if (!file) {
        perror(pathStr);
        return NULL;
    }
    
    aiff = malloc(sizeof(*aiff));
    aiff->file = file;
    
    fread(&chunkHeader, 1, sizeof(chunkHeader), aiff->file);
    chunkHeader.chunkID = BigLong(chunkHeader.chunkID);
    if (chunkHeader.chunkID != 'FORM') {
        Con_DWarning("AIFFOpen: chunkID is not 'FORM'\n");
        AIFFClose(aiff);
        return NULL;
    }
    chunkHeader.fileType = BigLong(chunkHeader.fileType);
    if (chunkHeader.fileType != 'AIFC') {
        Con_DWarning("AIFFOpen: file format is not 'AIFC'\n");
        AIFFClose(aiff);
        return NULL;
    }
    
    // Skip up to the 'SSND' chunk, ignoring all the type, compression, format, chunks.
    while (1) {
        fread(&chunk, 1, sizeof(chunk), aiff->file);
        chunk.chunkID = BigLong(chunk.chunkID);
        chunk.chunkSize = BigLong(chunk.chunkSize);
        
        if (chunk.chunkID == 'SSND')
            break;
        
        Con_DPrintf("AIFFOpen: skipping chunk %c%c%c%c\n", 
                    (chunk.chunkID >> 24) & 0xff, 
                    (chunk.chunkID >> 16) & 0xff, 
                    (chunk.chunkID >> 8) & 0xff, 
                    (chunk.chunkID >> 0) & 0xff);
        
        // Skip the chunk data
        fseek(aiff->file, chunk.chunkSize, SEEK_CUR);
    }
    
    Con_DPrintf("AIFFOpen: Found SSND, size = %d\n", chunk.chunkSize);
    
    fread(&ssndData, 1, sizeof(ssndData), aiff->file);
    ssndData.offset =  BigLong(ssndData.offset);
    ssndData.blockSize = BigLong(ssndData.blockSize);
    
    Con_DPrintf("AIFFOpen: offset = %d\n", ssndData.offset);
    Con_DPrintf("AIFFOpen: blockSize = %d\n", ssndData.blockSize);
    
    return aiff;
}

void AIFFClose(AIFFInfo *aiff)
{
    if (aiff) {
        fclose(aiff->file);
        free(aiff);
        aiff = NULL;
    }
}

/* ------------------------------------------------------------------------------------ */

/*
====================
CoreAudio IO Proc
====================
*/

OSStatus audioDeviceIOProc(AudioDeviceID inDevice,
                           const AudioTimeStamp *inNow,
                           const AudioBufferList *inInputData,
                           const AudioTimeStamp *inInputTime,
                           AudioBufferList *outOutputData,
                           const AudioTimeStamp *inOutputTime,
                           void *inClientData)
{
    unsigned int sampleIndex, sampleCount;
    float *outBuffer;
    float scale = (old_cdvolume / 32768.0f);
    
    // The buffer that we need to fill
    outBuffer = (float *)outOutputData->mBuffers[0].mData;
    
    // Read some samples from the file.
    sampleCount = fread(samples, sizeof(*samples), SAMPLES_PER_BUFFER, aiffInfo->file);
    if (sampleCount < SAMPLES_PER_BUFFER) {
        if (feof(aiffInfo->file)) {
            if (playLooping) {
                fseek(aiffInfo->file, 0L, SEEK_SET);
            }
        }
    }
    
    // Convert whatever samples we got into floats. Scale the floats to be [-1..1].
    for (sampleIndex = 0; sampleIndex < sampleCount; sampleIndex++) {
        // Convert the samples from shorts to floats.  Scale the floats to be [-1..1].
        outBuffer[sampleIndex] = samples[sampleIndex] * scale;
    }
    
    // Fill in zeros in the rest of the buffer
    for (; sampleIndex < SAMPLES_PER_BUFFER; sampleIndex++)
        outBuffer[sampleIndex] = 0.0;
    
    return kAudioHardwareNoError;
}

static void CDAudio_Eject(void)
{
	
}

static void CDAudio_CloseDoor(void)
{
	
}

/* ------------------------------------------------------------------------------------ */

static int CDAudio_GetAudioDiskInfo(void)
{
    NSDirectoryEnumerator *dirEnum;
    NSFileManager *fileManager;
    unsigned int mountCount;
    struct statfs  *mounts;
    NSString *mountPath;
    NSString *filePath;
    
    // Get rid of old info
    [cdTracks release];
    cdTracks = [[NSMutableArray alloc] init];
    
    cdValid = false;
    
    // Get the list of file system mount points
    mountCount = getmntinfo(&mounts, MNT_NOWAIT);
    if (mountCount <= 0) {
        Con_DWarning("GetAudioDiskInfo: getmntinfo failed");
        return -1;
    }
    
    fileManager = [NSFileManager defaultManager];
    while (mountCount--) {
        // CDs are read-only.
        if ((mounts[mountCount].f_flags & MNT_RDONLY) != MNT_RDONLY)
            continue;
        
        // CDs are not network filesystems
        if ((mounts[mountCount].f_flags & MNT_LOCAL) != MNT_LOCAL)
            continue;
        
        // Check the file system type just to be extra sure
        if (strcmp(mounts[mountCount].f_fstypename, "cddafs"))
            continue;
        
        // No slash in the mount point!  How is that possible?
        if (!strrchr(mounts[mountCount].f_mntonname, '/'))
            continue;
        
        // This looks good
        Con_DPrintf("FOUND CD:\n");
        Con_DPrintf("   type: %d\n", mounts[mountCount].f_type);
        Con_DPrintf("   flags: %u\n", mounts[mountCount].f_flags);
        Con_DPrintf("   fstype: %s\n", mounts[mountCount].f_fstypename);
        Con_DPrintf("   f_mntonname: %s\n", mounts[mountCount].f_mntonname);
        Con_DPrintf("   f_mntfromname: %s\n", mounts[mountCount].f_mntfromname);
        
        mountPath = [NSString stringWithCString: mounts[mountCount].f_mntonname encoding:NSUTF8StringEncoding];
        dirEnum = [fileManager enumeratorAtPath: mountPath];
        while ((filePath = [dirEnum nextObject])) {
            if ([[filePath pathExtension] isEqualToString: @"aiff"] || 
                [[filePath pathExtension] isEqualToString: @"cdda"])
                [cdTracks addObject: [mountPath stringByAppendingPathComponent: filePath]];
        }
    }
    
    if (![cdTracks count]) {
        [cdTracks release];
        cdTracks = NULL;
        Con_DPrintf("CDAudio: no music tracks\n");
        return -1;
    }
    
	cdValid = true;
    maxTrack = [cdTracks count];
    
	return 0;
}

void CDAudio_Play(byte track, qboolean looping)
{
	if (!enabled)
		return;
    
	if (!cdValid) {
		CDAudio_GetAudioDiskInfo();
		if (!cdValid)
			return;
	}
    
	track = remap[track];
    
    if (track < 1 || track > maxTrack) {
        Con_DPrintf("CDAudio: Bad track number %u.\n", track);
        return;
    }
	
    if (playing) {
		if (playTrack == track)
			return;
		CDAudio_Stop();
	}
    
    aiffInfo = AIFFOpen([cdTracks objectAtIndex:track - 1]);
    
    OSStatus status = AudioDeviceStart(audioDevice, ioprocid);
    if (status) {
        Con_DPrintf("CDAudio_Play: failed (%d)\n", status);
        return;
    } 
    
    playLooping = looping;    
    playTrack = track;
    playing = true;
    
    if (bgmvolume.value == 0.0)
		CDAudio_Pause ();
}

void CDAudio_Stop(void)
{
	if (!enabled)
		return;
    
    if (!playing)
		return;

    OSStatus status = AudioDeviceStop(audioDevice, ioprocid);
    if (status) {
        Con_DPrintf("CDAudio_Stop: failed (%d)\n", status);
    }
    
	wasPlaying = false;
	playing = false;
    
    AIFFClose(aiffInfo);
}

void CDAudio_Pause(void)
{
	if (!enabled)
		return;
    
    if (!playing)
		return;
    
    OSStatus status = AudioDeviceStop(audioDevice, ioprocid);
    if (status) {
        Con_DPrintf("CDAudio_Pause: failed (%d)\n", status);
    }
    
    wasPlaying = playing;
	playing = false;
}

void CDAudio_Resume(void)
{
	if (!enabled)
		return;
    
	if (!cdValid)
		return;
    
    if (!wasPlaying)
		return;
    
    OSStatus status = AudioDeviceStart (audioDevice, ioprocid);
    if (status) {
        Con_DPrintf("CDAudio_Resume: failed (%d)\n", status);
    }
    
	playing = true;
}

static void CD_f (void)
{
	char	*command;
	int		ret;
	int		n;
    
	if (Cmd_Argc() < 2)
	{
		Con_Printf("commands: ");
		Con_Printf("on, off, reset, remap, \n");
		Con_Printf("play, stop, loop, pause, resume\n");
		Con_Printf("eject, close, info\n");
		return;
	}
    
	command = Cmd_Argv (1);
    
	if (strcasecmp(command, "on") == 0)
	{
		enabled = true;
		return;
	}
    
	if (strcasecmp(command, "off") == 0)
	{
		if (playing)
			CDAudio_Stop();
        
		enabled = false;
		return;
	}
    
	if (strcasecmp(command, "reset") == 0)
	{
		enabled = true;
        
		if (playing)
			CDAudio_Stop();
        
		for (n = 0; n < 100; n++)
			remap[n] = n;
        
		CDAudio_GetAudioDiskInfo();
		return;
	}
    
	if (strcasecmp(command, "remap") == 0)
	{
		ret = Cmd_Argc() - 2;
		if (ret <= 0)
		{
			for (n = 1; n < 100; n++)
				if (remap[n] != n)
					Con_Printf("  %u -> %u\n", n, remap[n]);
			return;
		}
		for (n = 1; n <= ret; n++)
			remap[n] = atoi(Cmd_Argv (n+1));
		return;
	}
    
	if (strcasecmp(command, "close") == 0)
	{
		CDAudio_CloseDoor();
		return;
	}
    
	if (!cdValid)
	{
		CDAudio_GetAudioDiskInfo();
		if (!cdValid)
		{
			Con_Printf("No CD in drive\n");
			return;
		}
	}
    
	if (strcasecmp(command, "play") == 0)
	{
		CDAudio_Play((byte)atoi(Cmd_Argv (2)), false);
		return;
	}
    
	if (strcasecmp(command, "loop") == 0)
	{
		CDAudio_Play((byte)atoi(Cmd_Argv (2)), true);
		return;
	}
    
	if (strcasecmp(command, "stop") == 0)
	{
		CDAudio_Stop();
		return;
	}
    
	if (strcasecmp(command, "pause") == 0)
	{
		CDAudio_Pause();
		return;
	}
    
	if (strcasecmp(command, "resume") == 0)
	{
		CDAudio_Resume();
		return;
	}
    
	if (strcasecmp(command, "eject") == 0)
	{
		if (playing)
			CDAudio_Stop();
        
		CDAudio_Eject();
        
		cdValid = false;
		return;
	}
    
	if (strcasecmp(command, "info") == 0)
	{
		Con_Printf("%u tracks\n", maxTrack);
        
		if (playing)
			Con_Printf("Currently %s track %u\n", playLooping ? "looping" : "playing", playTrack);
		else if (wasPlaying)
			Con_Printf("Paused %s track %u\n", playLooping ? "looping" : "playing", playTrack);
        
		Con_Printf("Volume is %f\n", bgmvolume.value);
		return;
	}
}

static void CDAudio_SetVolume (cvar_t *var)
{
	if (var->value < 0.0)
		Cvar_SetValue (var->name, 0.0);
	else if (var->value > 1.0)
		Cvar_SetValue (var->name, 1.0);
	old_cdvolume = var->value;
    
	if (old_cdvolume == 0.0)
		CDAudio_Pause ();
	else
		CDAudio_Resume();
}

void CDAudio_Update(void)
{
	if (!enabled)
		return;
    
	if (old_cdvolume != bgmvolume.value)
		CDAudio_SetVolume (&bgmvolume);
}

int CDAudio_Init(void)
{
	int i;
    
	if (cls.state == ca_dedicated)
		return -1;
    
	if (COM_CheckParm("-nocdaudio"))
		return -1;
    
    Cmd_AddCommand ("cd", CD_f);
    
    Cvar_RegisterVariable(&bgmvolume, NULL);
	Cvar_RegisterVariable(&bgmtype, NULL);
    
    samples = (short *)malloc(SAMPLES_PER_BUFFER * sizeof(*samples));
    
    // Add cd IOProcID
    OSStatus status = AudioDeviceCreateIOProcID(audioDevice, audioDeviceIOProc, NULL, &ioprocid);
    if (status) {
        Con_DPrintf("AudioDeviceAddIOProc: returned %d\n", status);
        return -1;
    }
    if (ioprocid == NULL) {
        Con_DPrintf("Cannot create IOProcID\n");
        return -1;
    }
    
	for (i = 0; i < 100; i++)
		remap[i] = i;
    
    initialized = true;
    enabled = true;
	old_cdvolume = bgmvolume.value;
    
    Con_Printf("CD Audio initialized (using CoreAudio)\n");
    
    if (CDAudio_GetAudioDiskInfo()) {
        Con_Printf("No CD in drive\n");
		cdValid = false;
    }
    
	return 0;
}

void CDAudio_Shutdown(void)
{
    if (!initialized)
		return;
    
    CDAudio_Stop();
    
    // Remove cd IOProcID
    OSStatus status = AudioDeviceDestroyIOProcID(audioDevice, ioprocid);
    if (status) {
        Con_DPrintf("AudioDeviceRemoveIOProc: returned %d\n", status);
    }
    
    if (cdTracks) {
        [cdTracks release];
        cdTracks = NULL;
    }
    
    initialized = false;
}

