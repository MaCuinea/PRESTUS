function [medium_masks, segmented_image_cropped, skull_edge, trans_pos_final, focus_pos_final,...
    t1_image, t1_header, final_transformation_matrix, inv_final_transformation_matrix] = preprocess_brain(parameters, subject_id)
       
    % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % %
    %                  Preprocessing of structural data                 %
    %                                                                   %
    % This function combines Matlab and SimNIBS to segment, realign and %
    % crop the structural data for use in simulations.                  %
    % This is done both to allow k-wave to use different simulation     %
    % parameters for the skin, bone and neural tissue and to create     %
    % figures that allows one to view the simulation results.           %
    % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % % %

    %% CHECK INPUTS AND TRANSLATE PATTERNS
    disp('Checking inputs...')
    
    filename_t1 = fullfile(parameters.data_path, sprintf(parameters.t1_path_template, subject_id));
    filename_t2 = fullfile(parameters.data_path, sprintf(parameters.t2_path_template, subject_id));
    
    % Imports the localite location data in case this is enabled in the
    % config file
    files_to_check = ["filename_t1", "filename_t2"];
    if isfield(parameters,'transducer_from_localite') && parameters.transducer_from_localite
        localite_file = fullfile(parameters.data_path, sprintf(parameters.localite_instr_file_template, subject_id));
        files_to_check = [files_to_check, "localite_file"];
    end

    % Goes through 'files_to_check' to do exactly that
    for filename_var = files_to_check
        eval(sprintf('filename = %s;',  filename_var ))
        % if there is a wildcard in the string, use dir to find file
        if contains(filename, '*')
            matching_files = dir(filename);
            if length(matching_files)>1
                error('More than 1 file matches the template %s', filename)
            elseif isempty(matching_files)
                error('No files match the template %s', filename)
            else 
                filename = fullfile(matching_files.folder , matching_files.name);
                eval(sprintf('%s = filename;',  filename_var ))
            end
        end

        if ~isfile(filename)
            error('File does not exist: \r\n%s', filename);
        end
    end
    %% LOAD AND PROCESS t1 IMAGE (OR CT IMAGE OR CONTRAST IMAGE)
    disp('Loading T1...')

    % load mri image
    t1_image = niftiread(filename_t1);
    t1_header= niftiinfo(filename_t1);

    % Positions the transducer on original (unrotated) T1 
    if isfield(parameters,'transducer_from_localite') && parameters.transducer_from_localite
        % Takes the localite's transducer location
        [trans_pos_grid, focus_pos_grid, ~, ~] = ...
            position_transducer_localite(localite_file, t1_header, parameters);
    else
        % If the localite file is not used, it takes the transducer
        % location from the config file
        trans_pos_grid = parameters.transducer.pos_t1_grid';
        focus_pos_grid = parameters.focus_pos_t1_grid';
    end
    
    if size(trans_pos_grid,1)>size(trans_pos_grid, 2)
        trans_pos_grid = trans_pos_grid';
        focus_pos_grid = focus_pos_grid';
    end


    % Creates and exports an unprocessed T1 slice that is oriented 
    % along the transducer's axis
    [t1_with_trans_img, transducer_pars] = plot_t1_with_transducer(t1_image, t1_header.PixelDimensions(1), trans_pos_grid, focus_pos_grid, parameters);
    imshow(t1_with_trans_img);
    title('T1 with transducer');
    export_fig(fullfile(parameters.output_dir, sprintf('sub-%03d_t1_with_transducer_orig%s.png', subject_id, parameters.results_filename_affix)), '-native');
    close;
    
    %% SEGMENTATION using SimNIBS
    disp('Starting segmentation...')

    % Defines the names for the output folder of the segmented data
    segmentation_folder = fullfile(parameters.data_path, sprintf('m2m_sub-%03d', subject_id));
    if strcmp(parameters.segmentation_software, 'charm')
        filename_segmented = fullfile(segmentation_folder, 'final_tissues.nii.gz');
    else 
        filename_segmented = fullfile(segmentation_folder, sprintf('sub-%03d_final_contr.nii.gz', subject_id));
    end
    % Starts the segmentation, see 'run_headreco' for more documentation
    if confirm_overwriting(filename_segmented, parameters) && (~isfield( parameters,'overwrite_simnibs') || parameters.overwrite_simnibs || ~exist(filename_segmented, 'file'))
        % Asks for confirmation since segmentation takes a long time
        if parameters.interactive == 0 || confirmation_dlg('This will run SEGMENTATION WITH SIMNIBS that takes a long time, are you sure?', 'Yes', 'No')
            run_segmentation(parameters.data_path, subject_id, filename_t1, filename_t2,  parameters);
            %fprintf('\nThe script will continue with other subjects in the meanwhile...\n')
            medium_masks = [];
            segmented_image_cropped = [];
            skull_edge = [];
            trans_pos_final = [];
            focus_pos_final = [];
            final_transformation_matrix = [];
            inv_final_transformation_matrix = [];
            return;
        end
    else
        disp('Skipping, the file already exists, loading it instead.')
    end

    %% Rotate to match the stimulation trajectory
    disp('Rotating to match the focus axis...')

    % If the headreco process was not succesfull, it will stop preprocessing
    assert(exist(filename_segmented,'file')>0, ...
        'Head segmentation is not completed (%s does not exist), see logs in the batch_logs folder and in %s folder',...
            filename_segmented, segmentation_folder)

    % Defines output file location and name
    filename_reoriented_scaled_data = fullfile(parameters.output_dir, ...
        sprintf('sub-%03d_after_rotating_and_scaling%s.mat', subject_id, parameters.results_filename_affix));

    % Starts the process of rotating the segmented data
    segmented_img_orig = niftiread(filename_segmented);
    segmented_hdr_orig = niftiinfo(filename_segmented);

    
    if confirm_overwriting(filename_reoriented_scaled_data, parameters)

        % Introduces a scaling factor based on the difference between the
        % segmented file and the original T1 file
        scale_factor = segmented_hdr_orig.PixelDimensions(1)/parameters.grid_step_mm;

        % The function to rotate and scale the segmented T1 to line up with the transducer's axis
        [segmented_img_rr, trans_pos_upsampled_grid, focus_pos_upsampled_grid, scale_rotate_recenter_matrix, rotation_matrix, ~, ~, segm_img_montage] = ...
            align_to_focus_axis_and_scale(segmented_img_orig, segmented_hdr_orig, trans_pos_grid, focus_pos_grid, scale_factor, parameters);
        figure;
        imshow(segm_img_montage)
        title('Rotated (left) and original (right) segmented T1');
        export_fig(fullfile(parameters.output_dir, sprintf('sub-%03d_after_rotating_and_scaling_segmented%s.png', subject_id, parameters.results_filename_affix)),'-native');
        close;

        % The function to rotate and scale the original T1 to line up with the transducer's axis
        [t1_img_rr, ~, ~, ~, ~, ~, ~, t1_rr_img_montage] = align_to_focus_axis_and_scale(t1_image, t1_header, trans_pos_grid, focus_pos_grid, scale_factor, parameters);
        figure;
        imshow(t1_rr_img_montage)
        title('Rotated (left) and original (right) original T1');
        export_fig(fullfile(parameters.output_dir, sprintf('sub-%03d_after_rotating_and_scaling_orig%s.png', subject_id, parameters.results_filename_affix)),'-native');
        close;
        
        if strcmp(parameters.segmentation_software, 'charm') % create filled bone mask as charm doesn't make it itself
            bone_img_rr = segmented_img_rr>0&(segmented_img_rr<=4|segmented_img_rr>=7);
        else
            filename_bone_headreco = fullfile(segmentation_folder, sprintf('bone.nii.gz', subject_id));
    
            bone_img = niftiread(filename_bone_headreco);
    
            [bone_img_rr, ~, ~, ~, ~, ~, ~, bone_img_montage] = align_to_focus_axis_and_scale(bone_img, segmented_hdr_orig, trans_pos_grid, focus_pos_grid, scale_factor, parameters);
            figure;
            imshow(bone_img_montage)
            title('Rotated (left) and original (right) original bone mask');
    %         export_fig(fullfile(parameters.output_dir, sprintf('sub-%03d_after_rotating_and_scaling_orig%s.png', subject_id, parameters.results_filename_affix)),'-native');
            close;

        end

        
        assert(isequal(size(trans_pos_upsampled_grid,1:2),size(focus_pos_upsampled_grid, 1:2)),...
            "After reorientation, the first two coordinates of the focus and the transducer should be the same")

        % Saves the output according to the naming convention set in the
        % beginning of this section
        save(filename_reoriented_scaled_data, 'segmented_img_rr', 'trans_pos_upsampled_grid', 'bone_img_rr', 'focus_pos_upsampled_grid', 'scale_rotate_recenter_matrix', 'rotation_matrix', 't1_img_rr');
    else 
        disp('Skipping, the file already exists, loading it instead.')
        load(filename_reoriented_scaled_data);
    end

    %% Plot the skin & skull from SimNIBS

    % unsmoothed skull & skin masks
    if strcmp(parameters.segmentation_software, 'charm') % create filled bone mask
        skull_mask_unsmoothed = zeros(size(segmented_img_rr));
        skull_mask_unsmoothed(segmented_img_rr==7|segmented_img_rr==8) = segmented_img_rr(segmented_img_rr==7|segmented_img_rr==8);
    else
        skull_mask_unsmoothed = segmented_img_rr==4;
    end
    skin_mask_unsmoothed = segmented_img_rr==5;

    skin_slice = squeeze(skin_mask_unsmoothed(:,trans_pos_upsampled_grid(2),:));
    skull_slice = squeeze(skull_mask_unsmoothed(:,trans_pos_upsampled_grid(2),:));

    % Create a T1 slice for comparison to SimNIBS segmented data
    t1_slice =  repmat(mat2gray(squeeze(t1_img_rr(:,trans_pos_upsampled_grid(2),:))), [1 1 3]);
    % Create a slice of segmented SimNIBS data
    skin_skull_img = cat(3, zeros(size(skull_slice)), skin_slice, skull_slice);
    % Skull is blue, skin is green

    % Plot the different slices and an overlay for comparison
    montage(cat(4, t1_slice*255, skin_skull_img*255, imfuse(mat2gray(t1_slice), skin_skull_img, 'blend')) ,'size',[1 NaN]);
    title('T1 and SimNIBS skin (green) and skull (blue) masks');
    export_fig(fullfile(parameters.output_dir, sprintf('sub-%03d_t1_skin_skull%s.png', subject_id, parameters.results_filename_affix)), '-native')
    close;
    
    %% SMOOTH & CROP SKULL
    disp('Smoothing and cropping the skull...')

    % Defines output file location and name
    filename_cropped_smoothed_skull_data = fullfile(parameters.output_dir, sprintf('sub-%03d_%s_after_cropping_and_smoothing%s.mat', subject_id, parameters.simulation_medium, parameters.results_filename_affix));
    
    % Uses one of two functions to crop and smooth the skull based on
    % a parameter set in the config file
    % See each respected function for more documentation
    if confirm_overwriting(filename_cropped_smoothed_skull_data, parameters)
        if ~strcmp(parameters.simulation_medium, 'layered')
            [medium_masks, skull_edge, segmented_image_cropped, trans_pos_final, focus_pos_final, ~, ~, new_grid_size, crop_translation_matrix] = ...
            smooth_and_crop_skull(segmented_img_rr, bone_img_rr, parameters.grid_step_mm, trans_pos_upsampled_grid, focus_pos_upsampled_grid, parameters);
        else
            [medium_masks, skull_edge, segmented_image_cropped, trans_pos_final, focus_pos_final, ~, ~, new_grid_size, crop_translation_matrix] = ...
            smooth_and_crop_layered(segmented_img_rr, bone_img_rr, parameters.grid_step_mm, trans_pos_upsampled_grid, focus_pos_upsampled_grid, parameters);
        end

        % Combines the matrix that defined the alignment with the transducer
        % axis with the new matrix that defines the cropping of the skull
        final_transformation_matrix = scale_rotate_recenter_matrix*crop_translation_matrix';
        inv_final_transformation_matrix = maketform('affine', inv(final_transformation_matrix')');

        % Saves the output according to the naming convention set in the
        % beginning of this section
        save(filename_cropped_smoothed_skull_data, 'medium_masks', 'skull_edge', 'segmented_image_cropped', 'trans_pos_final', 'focus_pos_final', 'new_grid_size', 'crop_translation_matrix','final_transformation_matrix','inv_final_transformation_matrix')
    else 
        disp('Skipping, the file already exists, loading it instead.')
        load(filename_cropped_smoothed_skull_data);
    end    
    parameters.grid_dims = new_grid_size;

    % Creates and saves a figure with the segmented brain
    imwrite(plot_t1_with_transducer(medium_masks, parameters.grid_step_mm, trans_pos_final, focus_pos_final, parameters),...
        fullfile(parameters.output_dir, sprintf('sub-%03d_%s_segmented_brain_final%s.png', subject_id, parameters.simulation_medium, parameters.results_filename_affix)))

    % Check that the transformations are correct by inverting them and
    % comparing to the original 
    if ~exist('inv_final_transformation_matrix','var')
        final_transformation_matrix = scale_rotate_recenter_matrix*crop_translation_matrix';
        inv_final_transformation_matrix = maketform('affine', inv(final_transformation_matrix')');
    end

    % If the transformation cannot be correctly inverted, this will be displayed
    backtransf_coordinates = round(tformfwd([trans_pos_final; focus_pos_final], inv_final_transformation_matrix));
    if ~all(all(backtransf_coordinates ==[trans_pos_grid; focus_pos_grid]))
        disp('Backtransformed focus and transducer parameters differ from the original ones. Something went wrong (but note that small rounding errors could be possible.')
        disp('Original coordinates')
        disp([trans_pos_final, focus_pos_final]')
        disp('Backtransformed coordinates')
        disp(backtransf_coordinates)
        exit()
    end
    output_plot_name = fullfile(parameters.output_dir, sprintf('sub-%03d_positioning%s.png', subject_id, parameters.results_filename_affix));
    show_positioning_plots(segmented_img_orig, segmented_hdr_orig.PixelDimensions(1), trans_pos_grid, focus_pos_grid, ...
        segmented_image_cropped, trans_pos_final, focus_pos_final, parameters, output_plot_filename = output_plot_name)

end