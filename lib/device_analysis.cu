//#define GPU_ANALYSIS_DEBUG
//#define MSD_BOXCAR_TEST
//#define GPU_PARTIAL_TIMER
#define GPU_TIMER

//#define PEAK_FILTERING_INSIDE

//#define PEAK_FILTERING_OUTSIDE

#include <vector>
#include <stdio.h>
#include <stdlib.h>
#include "headers/params.h"

#include "headers/device_BC_plan.h"
#include "headers/device_peak_find.h"
#include "headers/device_MSD_plane_profile.h"
#include "headers/device_SPS_long.h"
#include "headers/device_threshold.h"

#include "timer.h"

//TODO:
// Make BC_plan for arbitrary long pulses, by reusing last element in the plane


void Create_list_of_boxcar_widths(std::vector<int> *boxcar_widths, std::vector<int> *BC_widths, int max_boxcar_width){
	int DIT_value, DIT_factor, width;
	DIT_value = 1;
	DIT_factor = 2;
	width = 0;
	for(int f=0; f<(int) BC_widths->size(); f++){
		for(int b=0; b<BC_widths->operator[](f); b++){
			width = width + DIT_value;
			if(width<=max_boxcar_width){
			boxcar_widths->push_back(width);
			}
		}
		DIT_value = DIT_value*DIT_factor;
	}
}

// Extend this to arbitrary size plans
void Create_PD_plan(std::vector<PulseDetection_plan> *PD_plan, std::vector<int> *BC_widths, int nDMs, int nTimesamples){
	int Elements_per_block, itemp, nRest;
	PulseDetection_plan PDmp;
	
	if(BC_widths->size()>0){
		PDmp.shift        = 0;
		PDmp.output_shift = 0;
		PDmp.startTaps    = 0;
		PDmp.iteration    = 0;
		
		PDmp.decimated_timesamples = nTimesamples;
		PDmp.dtm = (nTimesamples>>(PDmp.iteration+1));
		PDmp.dtm = PDmp.dtm - (PDmp.dtm&1);
		
		PDmp.nBoxcars = BC_widths->operator[](0);
		Elements_per_block = PD_NTHREADS*2 - PDmp.nBoxcars;
		itemp = PDmp.decimated_timesamples;
		PDmp.nBlocks = itemp/Elements_per_block;
		nRest = itemp - PDmp.nBlocks*Elements_per_block;
		if(nRest>0) PDmp.nBlocks++;
		PDmp.unprocessed_samples = PDmp.nBoxcars + 6;
		if(PDmp.decimated_timesamples<PDmp.unprocessed_samples) PDmp.nBlocks=0;
		PDmp.total_ut = PDmp.unprocessed_samples;
		
		
		PD_plan->push_back(PDmp);
		
		for(int f=1; f< (int) BC_widths->size(); f++){
			// These are based on previous values of PDmp
			PDmp.shift        = PDmp.nBoxcars/2;
			PDmp.output_shift = PDmp.output_shift + PDmp.decimated_timesamples;
			PDmp.startTaps    = PDmp.startTaps + PDmp.nBoxcars*(1<<PDmp.iteration);
			PDmp.iteration    = PDmp.iteration + 1;
			
			// Definition of new PDmp values
			PDmp.decimated_timesamples = PDmp.dtm;
			PDmp.dtm = (nTimesamples>>(PDmp.iteration+1));
			PDmp.dtm = PDmp.dtm - (PDmp.dtm&1);
			
			PDmp.nBoxcars = BC_widths->operator[](f);
			Elements_per_block=PD_NTHREADS*2 - PDmp.nBoxcars;
			itemp = PDmp.decimated_timesamples;
			PDmp.nBlocks = itemp/Elements_per_block;
			nRest = itemp - PDmp.nBlocks*Elements_per_block;
			if(nRest>0) PDmp.nBlocks++;
			PDmp.unprocessed_samples = PDmp.unprocessed_samples/2 + PDmp.nBoxcars + 6; //
			if(PDmp.decimated_timesamples<PDmp.unprocessed_samples) PDmp.nBlocks=0;
			PDmp.total_ut = PDmp.unprocessed_samples*(1<<PDmp.iteration);
			
			PD_plan->push_back(PDmp);
		}
	}
}


int Get_max_iteration(int max_boxcar_width, std::vector<int> *BC_widths, int *max_width_performed){
	int startTaps, iteration;
	
	startTaps = 0;
	iteration = 0;
	for(int f=0; f<(int) BC_widths->size(); f++){
		startTaps = startTaps + BC_widths->operator[](f)*(1<<f);
		if(startTaps>=max_boxcar_width) {
			iteration = f+1;
			break;
		}
	}
	
	if(max_boxcar_width>startTaps) {
		iteration=(int) BC_widths->size();
	}
	
	*max_width_performed=startTaps;
	return(iteration);
}


void analysis_GPU(float *h_peak_list, size_t *peak_pos, size_t max_peak_size, int i, float tstart, int t_processed, int inBin, int outBin, int *maxshift, int max_ndms, int *ndms, float cutoff, float OR_sigma_multiplier, float max_boxcar_width_in_sec, float *output_buffer, float *dm_low, float *dm_high, float *dm_step, float tsamp, int candidate_algorithm, int enable_sps_baselinenoise){
	//--------> Task
	int max_boxcar_width = (int) (max_boxcar_width_in_sec/tsamp);
	int max_width_performed=0;
	size_t vals;
	int nTimesamples = t_processed;
	int nDMs = ndms[i];
	int temp_peak_pos = 0;
	int local_peak_pos = 0;
	
	//--------> Benchmarking
	double total_time=0, MSD_time=0, SPDT_time=0, PF_time=0;
	
	//--------> Other
	size_t free_mem,total_mem;
	char filename[200];
	
	
	// Calculate the total number of values
	vals = ((size_t) nDMs)*((size_t) nTimesamples);
	
	
	int max_iteration;
	int t_BC_widths[10]={PD_MAXTAPS,16,16,16,8,8,8,8,8,8};
	std::vector<int> BC_widths(t_BC_widths,t_BC_widths+sizeof(t_BC_widths)/sizeof(int));
	std::vector<PulseDetection_plan> PD_plan;

	//---------------------------------------------------------------------------
	//----------> GPU part
	printf("\n----------> GPU analysis part\n");
	printf("  Dimensions nDMs:%d; nTimesamples:%d; inBin:%d; outBin:%d; maxshift:%d; \n", ndms[i], t_processed, inBin, outBin, *maxshift);
	GpuTimer total_timer, timer;
	total_timer.Start();
	
	
	float *d_MSD;
	checkCudaErrors(cudaGetLastError());
	if ( cudaSuccess != cudaMalloc((void**) &d_MSD, sizeof(float)*3)) {printf("Allocation error!\n"); exit(201);}
	
	
	cudaMemGetInfo(&free_mem,&total_mem);
	printf("  Memory required by boxcar filters:%0.3f MB\n",(4.5*vals*sizeof(float) + 2*vals*sizeof(ushort))/(1024.0*1024) );
	printf("  Memory available:%0.3f MB \n", ((float) free_mem)/(1024.0*1024.0) );
	
	std::vector<int> DM_list;
	unsigned long int max_timesamples=(free_mem*0.95)/(5.5*sizeof(float) + 2*sizeof(ushort));
	int DMs_per_cycle = max_timesamples/nTimesamples;
	int nRepeats, nRest, DM_shift, itemp, local_max_list_size;//BC_shift,
	
	itemp = (int) (DMs_per_cycle/THR_WARPS_PER_BLOCK);
	DMs_per_cycle = itemp*THR_WARPS_PER_BLOCK;
	
	nRepeats = nDMs/DMs_per_cycle;
	nRest = nDMs - nRepeats*DMs_per_cycle;
	local_max_list_size = (DMs_per_cycle*nTimesamples)/4;
	
	for(int f=0; f<nRepeats; f++) DM_list.push_back(DMs_per_cycle);
	if(nRest>0) DM_list.push_back(nRest);
	
	if( (int) DM_list.size() > 1 ) 
		printf("  SPS will run %d batches each containing %d DM trials. Remainder %d DM trials\n", (int) DM_list.size(), DMs_per_cycle, nRest);
	else 
		printf("  SPS will run %d batch containing %d DM trials.\n", (int) DM_list.size(), nRest);
	
	
	max_iteration = Get_max_iteration(max_boxcar_width/inBin, &BC_widths, &max_width_performed);
	printf("  Selected iteration:%d; maximum boxcar width requested:%d; maximum boxcar width performed:%d;\n", max_iteration, max_boxcar_width/inBin, max_width_performed);
	Create_PD_plan(&PD_plan, &BC_widths, 1, nTimesamples);
	std::vector<int> h_boxcar_widths;
	Create_list_of_boxcar_widths(&h_boxcar_widths, &BC_widths, max_width_performed);
	
	
	//-------------------------------------------------------------------------
	//---------> Comparison between interpolated values and computed values
	#ifdef MSD_BOXCAR_TEST
		MSD_plane_profile_boxcars(output_buffer, nTimesamples, nDMs, &h_boxcar_widths, OR_sigma_multiplier, dm_low[i], dm_high[i], tstart);
	#endif
	//---------> Comparison between interpolated values and computed values
	//-------------------------------------------------------------------------
	
	
	
	//-------------------------------------------------------------------------
	//------------ Using MSD_plane_profile
	size_t MSD_profile_size_in_bytes, MSD_DIT_profile_size_in_bytes, workarea_size_in_bytes;
	cudaMemGetInfo(&free_mem,&total_mem);
	Get_MSD_plane_profile_memory_requirements(&MSD_profile_size_in_bytes, &MSD_DIT_profile_size_in_bytes, &workarea_size_in_bytes, nTimesamples, nDMs, &h_boxcar_widths);
	double dit_time, MSD_only_time;
	float *d_MSD_interpolated;
	float *d_MSD_DIT = NULL;
	float *temporary_workarea;
	cudaMalloc((void **) &d_MSD_interpolated, MSD_profile_size_in_bytes);
	cudaMalloc((void **) &temporary_workarea, workarea_size_in_bytes);
	
	MSD_plane_profile(d_MSD_interpolated, output_buffer, d_MSD_DIT, temporary_workarea, false, nTimesamples, nDMs, &h_boxcar_widths, tstart, dm_low[i], dm_high[i], OR_sigma_multiplier, enable_sps_baselinenoise, false, &MSD_time, &dit_time, &MSD_only_time);
	
	#ifdef GPU_PARTIAL_TIMER
		printf("    MSD time: Total: %f ms; DIT: %f ms; MSD: %f ms;\n", MSD_time, dit_time, MSD_only_time);
	#endif
	
	cudaFree(temporary_workarea);
	//------------ Using MSD_plane_profile
	//-------------------------------------------------------------------------	
	
	
	if(DM_list.size()>0){
		DMs_per_cycle = DM_list[0];
		
		float *d_peak_list;
		if ( cudaSuccess != cudaMalloc((void**) &d_peak_list, sizeof(float)*DMs_per_cycle*nTimesamples)) printf("Allocation error! peaks\n");
		
		float *d_decimated;
		if ( cudaSuccess != cudaMalloc((void **) &d_decimated,  sizeof(float)*(((DMs_per_cycle*nTimesamples)/2)+PD_MAXTAPS) )) printf("Allocation error! dedispered\n");
		
		float *d_boxcar_values;
		if ( cudaSuccess != cudaMalloc((void **) &d_boxcar_values,  sizeof(float)*DMs_per_cycle*nTimesamples)) printf("Allocation error! boxcars\n");
		
		float *d_output_SNR;
		if ( cudaSuccess != cudaMalloc((void **) &d_output_SNR, sizeof(float)*2*DMs_per_cycle*nTimesamples)) printf("Allocation error! SNR\n");
		
		ushort *d_output_taps;
		if ( cudaSuccess != cudaMalloc((void **) &d_output_taps, sizeof(ushort)*2*DMs_per_cycle*nTimesamples)) printf("Allocation error! taps\n");
		
		int *gmem_peak_pos;
		cudaMalloc((void**) &gmem_peak_pos, 1*sizeof(int));
		cudaMemset((void*) gmem_peak_pos, 0, sizeof(int));
		
		int *gmem_filteredpeak_pos;
		cudaMalloc((void**) &gmem_filteredpeak_pos, 1*sizeof(int));
		cudaMemset((void*) gmem_filteredpeak_pos, 0, sizeof(int));
		size_t d_output_SNR_size = 2*DMs_per_cycle*nTimesamples;
		size_t d_peak_list_size = DMs_per_cycle*nTimesamples;
		
		DM_shift = 0;
		for(int f=0; f<DM_list.size(); f++) {
			//-------------- SPDT
			timer.Start();
			SPDT_search_long_MSD_plane(&output_buffer[DM_shift*nTimesamples], d_boxcar_values, d_decimated, d_output_SNR, d_output_taps, d_MSD_interpolated, &PD_plan, max_iteration, nTimesamples, DM_list[f]);
			timer.Stop();
			SPDT_time += timer.Elapsed();
			#ifdef GPU_PARTIAL_TIMER
			printf("    SPDT took:%f ms\n", timer.Elapsed());
			#endif
			//-------------- SPDT
			
			checkCudaErrors(cudaGetLastError());
			
			#ifdef GPU_ANALYSIS_DEBUG
			printf("    BC_shift:%d; DMs_per_cycle:%d; f*DMs_per_cycle:%d; max_iteration:%d;\n", DM_shift*nTimesamples, DM_list[f], DM_shift, max_iteration);
			#endif
			
			if(candidate_algorithm==1){
				//-------------- Thresholding
				timer.Start();
				THRESHOLD(d_output_SNR, d_output_taps, d_peak_list, gmem_peak_pos, cutoff, DM_list[f], nTimesamples, DM_shift, &PD_plan, max_iteration, local_max_list_size);
				timer.Stop();
				PF_time += timer.Elapsed();
				#ifdef GPU_PARTIAL_TIMER
				printf("    Thresholding took:%f ms\n", timer.Elapsed());
				#endif
				//-------------- Thresholding
			}
			else {
				//-------------- Peak finding
				timer.Start();
				PEAK_FIND(d_output_SNR, d_output_taps, d_peak_list, DM_list[f], nTimesamples, cutoff, local_max_list_size, gmem_peak_pos, DM_shift, &PD_plan, max_iteration);
				timer.Stop();
				PF_time = timer.Elapsed();
				#ifdef GPU_PARTIAL_TIMER
				printf("    Peak finding took:%f ms\n", timer.Elapsed());
				#endif
				//-------------- Peak finding
			}
			
			checkCudaErrors(cudaGetLastError());
			
			#ifdef PEAK_FILTERING_INSIDE
				timer.Start();
				checkCudaErrors(cudaMemcpy(&temp_peak_pos, gmem_peak_pos, sizeof(int), cudaMemcpyDeviceToHost));
				printf("Number of points before filtering: %d;\n", temp_peak_pos);
				cudaMemset((void*) gmem_peak_pos, 0, sizeof(int));
				gpu_Filter_peaks(d_output_SNR, d_peak_list, temp_peak_pos, 14.0, d_peak_list_size/4, gmem_peak_pos);
				checkCudaErrors(cudaMemcpy(&temp_peak_pos, gmem_peak_pos, sizeof(int), cudaMemcpyDeviceToHost));
				printf("Number of points after filtering: %d;\n", temp_peak_pos);
				checkCudaErrors(cudaMemcpy(d_peak_list, d_output_SNR, temp_peak_pos*4*sizeof(float), cudaMemcpyDeviceToDevice));
				timer.Stop();
				printf("Peak filtering took: %f\n",timer.Elapsed());
			#endif
			
			checkCudaErrors(cudaMemcpy(&temp_peak_pos, gmem_peak_pos, sizeof(int), cudaMemcpyDeviceToHost));
			#ifdef GPU_ANALYSIS_DEBUG
			printf("    temp_peak_pos:%d; host_pos:%zu; max:%zu; local_max:%d;\n", temp_peak_pos, (*peak_pos), max_peak_size, local_max_list_size);
			#endif
			if( temp_peak_pos>=local_max_list_size ) {
				printf("    Maximum list size reached! Increase list size or increase sigma cutoff.\n");
				temp_peak_pos=local_max_list_size;
			}
			if( ((*peak_pos) + temp_peak_pos)<max_peak_size){
				checkCudaErrors(cudaMemcpy(&h_peak_list[(*peak_pos)*4], d_peak_list, temp_peak_pos*4*sizeof(float), cudaMemcpyDeviceToHost));
				*peak_pos = (*peak_pos) + temp_peak_pos;
				local_peak_pos = local_peak_pos + temp_peak_pos;
			}
			else printf("Error peak list is too small!\n");

			DM_shift = DM_shift + DM_list[f];
			cudaMemset((void*) gmem_peak_pos, 0, sizeof(int));
		}
		
		
		#ifdef PEAK_FILTERING_OUTSIDE
		//-----------------------------------------------
		//-------> Peak filtering
		timer.Start();
		printf("Number of peaks: %d; which is %f MB; d_output_SNR_size is %f MB;\n", local_peak_pos, (local_peak_pos*4.0*4.0)/(1024.0*1024.0), (d_output_SNR_size*4.0)/(1024.0*1024.0));
		if(d_output_SNR_size>local_peak_pos*4){
			printf("Number of points before filtering: %d;\n", local_peak_pos);
			cudaMemset((void*) d_output_SNR, 0, d_output_SNR_size*sizeof(float));
			cudaMemset((void*) d_peak_list, 0, d_peak_list_size*sizeof(float));
			checkCudaErrors(cudaMemcpy(d_output_SNR, h_peak_list, local_peak_pos*4*sizeof(float), cudaMemcpyHostToDevice));
			
			gpu_Filter_peaks(d_peak_list, d_output_SNR, local_peak_pos, 14.0, d_peak_list_size/4, gmem_filteredpeak_pos);
			
			checkCudaErrors(cudaMemcpy(&temp_peak_pos, gmem_filteredpeak_pos, sizeof(int), cudaMemcpyDeviceToHost));
			local_peak_pos = temp_peak_pos;
			printf("Number of points after filtering: %d;\n", local_peak_pos);
			checkCudaErrors(cudaMemcpy(h_peak_list, d_peak_list, local_peak_pos*4*sizeof(float), cudaMemcpyDeviceToHost));
		}
		else {
			printf("Not enough memory to perform peak filtering!\n");
		}
		timer.Stop();
		printf("Peak filtering took: %f\n",timer.Elapsed());
		
		checkCudaErrors(cudaGetLastError());
		#endif
		
		
		//------------------------> Output
		#pragma omp parallel for
		for (int count = 0; count < local_peak_pos; count++){
			h_peak_list[4*count]     = h_peak_list[4*count]*dm_step[i] + dm_low[i];
			h_peak_list[4*count + 1] = h_peak_list[4*count + 1]*tsamp + tstart;
			h_peak_list[4*count + 2] = h_peak_list[4*count + 2];
			h_peak_list[4*count + 3] = h_peak_list[4*count + 3]*inBin;
		}
        
		FILE *fp_out;
		
		if(candidate_algorithm==1){
			if((*peak_pos)>0){
				sprintf(filename, "analysed-t_%.2f-dm_%.2f-%.2f.dat", tstart, dm_low[i], dm_high[i]);
				if (( fp_out = fopen(filename, "wb") ) == NULL)	{
					fprintf(stderr, "Error opening output file!\n");
					exit(0);
				}
				fwrite(h_peak_list, local_peak_pos*sizeof(float), 4, fp_out);
				fclose(fp_out);
			}
		}
		else {
			if((*peak_pos)>0){
				sprintf(filename, "peak_analysed-t_%.2f-dm_%.2f-%.2f.dat", tstart, dm_low[i], dm_high[i]);
				if (( fp_out = fopen(filename, "wb") ) == NULL)	{
					fprintf(stderr, "Error opening output file!\n");
					exit(0);
				}
				fwrite(h_peak_list, local_peak_pos*sizeof(float), 4, fp_out);
				fclose(fp_out);
			}
		}
		//------------------------> Output
		
		cudaFree(d_peak_list);
		cudaFree(d_boxcar_values);
		cudaFree(d_decimated);
		cudaFree(d_output_SNR);
		cudaFree(d_output_taps);
		cudaFree(gmem_peak_pos);
		cudaFree(d_MSD_DIT);
		cudaFree(d_MSD_interpolated);
		
		cudaFree(gmem_filteredpeak_pos);

	}
	else printf("Error not enough memory to search for pulses\n");

	total_timer.Stop();
	total_time = total_timer.Elapsed();
	#ifdef GPU_TIMER
	printf("\n  TOTAL TIME OF SPS:%f ms\n", total_time);
	printf("  MSD_time: %f ms; SPDT time: %f ms; Candidate selection time: %f ms;\n", MSD_time, SPDT_time, PF_time);
	printf("----------<\n\n");
	#endif

	cudaFree(d_MSD);
	//----------> GPU part
	//---------------------------------------------------------------------------
	
}
