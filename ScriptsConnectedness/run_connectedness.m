% [INPUT]
% data = A structure representing the dataset.
% out_temp = A string representing the full path to the Excel spreadsheet used as a template for the results file.
% out_file = A string representing the full path to the Excel spreadsheet to which the results are written, eventually replacing the previous ones.
% bandwidth = An integer greater than or equal to 30 representing the bandwidth (dimension) of each rolling window (optional, default=252).
% significance = A float (0.00,0.20] representing the statistical significance threshold for the linear Granger-causality test (optional, default=0.05).
% robust = A boolean indicating whether to use robust p-values for the linear Granger-causality test (optional, default=true).
% k = A float (0.00,0.20] representing the Granger-causality threshold for no causal relationships (optional, default=0.06).
% lags = An integer [1,5] representing the number of lags of the VAR model for the variance decomposition spillovers (optional, default=2).
% h = An integer [1,15] representing the prediction horizon for the variance decomposition spillovers (optional, default=4).
% generalized = A boolean indicating whether to use the Generalised FEVD for the variance decomposition spillovers (optional, default=true).
% analyze = A boolean that indicates whether to analyse the results and display plots (optional, default=false).
%
% [OUTPUT]
% result = A structure representing the original dataset inclusive of intermediate and final calculations.

function result = run_connectedness(varargin)

    persistent ip;

    if (isempty(ip))
        ip = inputParser();
        ip.addRequired('data',@(x)validateattributes(x,{'struct'},{'nonempty'}));
        ip.addRequired('out_temp',@(x)validateattributes(x,{'char'},{'nonempty','size',[1,NaN]}));
        ip.addRequired('out_file',@(x)validateattributes(x,{'char'},{'nonempty','size',[1,NaN]}));
        ip.addOptional('bandwidth',252,@(x)validateattributes(x,{'numeric'},{'scalar','integer','real','finite','>=',30}));
        ip.addOptional('significance',0.05,@(x)validateattributes(x,{'double','single'},{'scalar','real','finite','>',0,'<=',0.20}));
        ip.addOptional('robust',true,@(x)validateattributes(x,{'logical'},{'scalar'}));
        ip.addOptional('k',0.06,@(x)validateattributes(x,{'double','single'},{'scalar','real','finite','>',0,'<=',0.20}));
        ip.addOptional('analyze',false,@(x)validateattributes(x,{'logical'},{'scalar'}));
    end

    ip.parse(varargin{:});

    ipr = ip.Results;
    data = validate_data(ipr.data);
    out_temp = validate_template(ipr.out_temp);
    out_file = validate_output(ipr.out_file);
    
    result = run_connectedness_internal(data,out_temp,out_file,ipr.bandwidth,ipr.significance,ipr.robust,ipr.k,ipr.analyze);

end

function result = run_connectedness_internal(data,out_temp,out_file,bandwidth,significance,robust,k,analyze)

    result = [];
    
    bar = waitbar(0,'Calculating connectedness measures...','CreateCancelBtn',@(src,event)setappdata(gcbf(),'Stop',true));
    setappdata(bar,'Stop',false);
    
    windows = extract_rolling_windows(data.FirmReturns,bandwidth);
    windows_len = length(windows);

    data = data_initialize(data,windows_len,bandwidth,significance,robust,k);

    futures(1:windows_len) = parallel.FevalFuture;
    futures_max = 0;
    futures_results = cell(windows_len,1);
    
    for i = 1:windows_len
       futures(i) = parfeval(@main_loop,1,windows{i},data.GroupDelimiters,significance,robust);
    end
    
    try
        stopped = false;
        
        for i = 1:windows_len
            if (getappdata(bar,'Stop'))
                stopped = true;
                break;
            end
            
            [future_index,value] = fetchNext(futures);
            futures_results{future_index} = value;
            
            futures_max = max([future_index futures_max]);
            waitbar((futures_max - 1) / windows_len,bar);

            if (getappdata(bar,'Stop'))
                stopped = true;
                break;
            end
        end
        
        if (stopped)
            try
                cancel(futures);
                delete(bar);
            catch
            end

            return;
        end

        data = data_finalize(data,futures_results);

        waitbar(100,bar,'Writing connectedness measures...');
        write_results(out_temp,out_file,data);
        
        try
            cancel(futures);
            delete(bar);
        catch
        end
    catch e
        try
            cancel(futures);
            delete(bar);
        catch
        end

        rethrow(e);
    end

    if (analyze)        
        plot_indicators(data);
        plot_network(data);
        plot_adjacency_matrix(data);
        plot_centralities(data);
        plot_pca(data);
    end
    
    result = data;

end

%% DATA

function data = data_initialize(data,windows_len,bandwidth,significance,robust,k)

    data.Bandwidth = bandwidth;
    data.K = k;
    data.Robust = robust;
    data.Significance = significance;
    data.Windows = windows_len;

    data.AdjacencyMatrices = cell(windows_len,1);
    data.DCI = NaN(data.T,1);
    data.ConnectionsInOut = NaN(data.T,1);
    data.ConnectionsInOutOther = NaN(data.T,1);
    data.BetweennessCentralities = NaN(data.T,data.N);
    data.ClosenessCentralities = NaN(data.T,data.N);
    data.DegreeCentralities = NaN(data.T,data.N);
    data.EigenvectorCentralities = NaN(data.T,data.N);
    data.KatzCentralities = NaN(data.T,data.N);
    data.ClusteringCoefficients = NaN(data.T,data.N);
    data.DegreesIn = NaN(data.T,data.N);
    data.DegreesOut = NaN(data.T,data.N);
    data.Degrees = NaN(data.T,data.N);

    data.PCACoefficients = cell(windows_len,1);
    data.PCAExplained = cell(windows_len,1);
    data.PCAExplainedSums = NaN(data.T,4);
    data.PCAScores = cell(windows_len,1);

end

function data = data_finalize(data,futures_results)

    for i = 1:data.Windows
        futures_result = futures_results{i};
        futures_result_off = data.Bandwidth + i - 1;

        data.AdjacencyMatrices{i} = futures_result.AdjacencyMatrix;
        data.DCI(futures_result_off) = futures_result.DCI;
        data.ConnectionsInOut(futures_result_off) = futures_result.ConnectionsInOut;
        data.ConnectionsInOutOther(futures_result_off) = futures_result.ConnectionsInOutOther;
        data.BetweennessCentralities(futures_result_off,:) = futures_result.BetweennessCentralities;
        data.ClosenessCentralities(futures_result_off,:) = futures_result.ClosenessCentralities;
        data.DegreeCentralities(futures_result_off,:) = futures_result.DegreeCentralities;
        data.EigenvectorCentralities(futures_result_off,:) = futures_result.EigenvectorCentralities;
        data.KatzCentralities(futures_result_off,:) = futures_result.KatzCentralities;
        data.ClusteringCoefficients(futures_result_off,:) = futures_result.ClusteringCoefficients;
        data.DegreesIn(futures_result_off,:) = futures_result.DegreesIn;
        data.DegreesOut(futures_result_off,:) = futures_result.DegreesOut;
        data.Degrees(futures_result_off,:) = futures_result.Degrees;
        
        data.PCACoefficients{i} = futures_result.PCACoefficients;
        data.PCAExplained{i} = futures_result.PCAExplained;
        data.PCAExplainedSums(futures_result_off,:) = fliplr([cumsum([futures_result.PCAExplained(1) futures_result.PCAExplained(2) exp(3)]) 100]);
        data.PCAScores{i} = futures_result.PCAScores;
    end

    a = sum(cat(3,data.AdjacencyMatrices{:}),3) ./ data.Windows;
    a_threshold = mean(mean(a));
    a(a < a_threshold) = 0;
    a(a >= a_threshold) = 1;
    data.AdjacencyMatrixAverage = a;
    
    [bc,cc,dc,ec,kc,clustering_coefficients,degrees_in,degrees_out,degrees] = calculate_centralities(a);
    data.BetweennessCentralitiesAverage = bc;
    data.ClosenessCentralitiesAverage = cc;
    data.DegreeCentralitiesAverage = dc;
    data.EigenvectorCentralitiesAverage = ec;
    data.KatzCentralitiesAverage = kc;
    data.ClusteringCoefficientsAverage = clustering_coefficients;
    data.DegreesInAverage = degrees_in;
    data.DegreesOutAverage = degrees_out;
    data.DegreesAverage = degrees;
    
    [pca_coefficients,pca_scores,~,~,pca_explained] = pca(data.FirmReturns,'Economy',false);
    data.PCACoefficientsOverall = pca_coefficients;
    data.PCAExplainedOverall = pca_explained;
    data.PCAScoresOverall = pca_scores;

end

function data = validate_data(data)

    fields = {'Full', 'T', 'N', 'DatesNum', 'DatesStr', 'MonthlyTicks', 'IndexName', 'IndexReturns', 'FirmNames', 'FirmReturns', 'Capitalizations', 'CapitalizationsLagged', 'Liabilities', 'SeparateAccounts', 'StateVariables', 'Groups', 'GroupDelimiters', 'GroupNames'};
    
    for i = 1:numel(fields)
        if (~isfield(data,fields{i}))
            error('The dataset does not contain all the required data.');
        end
    end
    
end

function out_file = validate_output(out_file)

    [path,name,extension] = fileparts(out_file);

    if (~strcmp(extension,'.xlsx'))
        out_file = fullfile(path,[name extension '.xlsx']);
    end
    
end

function out_temp = validate_template(out_temp)

    if (exist(out_temp,'file') == 0)
        error('The template file could not be found.');
    end
    
    if (ispc())
        [file_status,file_sheets,file_format] = xlsfinfo(out_temp);
        
        if (isempty(file_status) || ~strcmp(file_format,'xlOpenXMLWorkbook'))
            error('The dataset file is not a valid Excel spreadsheet.');
        end
    else
        [file_status,file_sheets] = xlsfinfo(out_temp);
        
        if (isempty(file_status))
            error('The dataset file is not a valid Excel spreadsheet.');
        end
    end
    
    sheets = {'Indicators' 'Average Adjacency Matrix' 'Average Centrality Measures' 'PCA Overall Explained' 'PCA Overall Coefficients' 'PCA Overall Scores'};

    if (~all(ismember(sheets,file_sheets)))
        error(['The template must contain the following sheets: ' sheets{1} sprintf(', %s', sheets{2:end}) '.']);
    end
    
    if (ispc())
        try
            excel = actxserver('Excel.Application');
            excel_wb = excel.Workbooks.Open(res,0,false);

            for i = 1:numel(sheets)
                excel_wb.Sheets.Item(sheets{i}).Cells.Clear();
            end
            
            excel_wb.Save();
            excel_wb.Close();
            excel.Quit();

            delete(excel);
        catch
        end
    end

end

function write_results(out_temp,out_file,data)

    [out_file_path,~,~] = fileparts(out_file);

    if (exist(out_file_path,'dir') ~= 7)
        mkdir(out_file_path);
    end

    if (exist(out_file,'file') == 2)
        delete(out_file);
    end
    
    copy_result = copyfile(out_temp,out_file,'f');
    
    if (copy_result == 0)
        error('The results file could not be created from the template file.');
    end

    firm_names = data.FirmNames';

    vars = [data.DatesStr num2cell(data.DCI) num2cell(data.ConnectionsInOut) num2cell(data.ConnectionsInOutOther)];
    labels = {'Date' 'DCI' 'Connections_InOut' 'Connections_InOutOther'};
    t1 = cell2table(vars,'VariableNames',labels);
    writetable(t1,out_file,'FileType','spreadsheet','Sheet','Indicators','WriteRowNames',true);

    vars = [firm_names num2cell(data.AdjacencyMatrixAverage)];
    labels = {'Firms' data.FirmNames{:,:}};
    t2 = cell2table(vars,'VariableNames',labels);
    writetable(t2,out_file,'FileType','spreadsheet','Sheet','Average Adjacency Matrix','WriteRowNames',true);

    vars = [firm_names num2cell(data.BetweennessCentralitiesAverage') num2cell(data.ClosenessCentralitiesAverage') num2cell(data.DegreeCentralitiesAverage') num2cell(data.EigenvectorCentralitiesAverage') num2cell(data.KatzCentralitiesAverage') num2cell(data.ClusteringCoefficientsAverage')];
    labels = {'Firms' 'BetweennessCentrality' 'ClosenessCentrality' 'DegreeCentrality' 'EigenvectorCentrality' 'KatzCentrality' 'ClusteringCoefficient'};
    t3 = cell2table(vars,'VariableNames',labels);
    writetable(t3,out_file,'FileType','spreadsheet','Sheet','Average Centrality Measures','WriteRowNames',true);

    vars = [num2cell(1:data.N)' num2cell(data.PCAExplainedOverall)];
    labels = {'PC' 'ExplainedVariance'};
    t4 = cell2table(vars,'VariableNames',labels);
    writetable(t4,out_file,'FileType','spreadsheet','Sheet','PCA Overall Explained','WriteRowNames',true);

    vars = [firm_names num2cell(data.PCACoefficientsOverall)];
    labels = {'Firms' data.FirmNames{:,:}};
    t5 = cell2table(vars,'VariableNames',labels);
    writetable(t5,out_file,'FileType','spreadsheet','Sheet','PCA Overall Coefficients','WriteRowNames',true);
    
    vars = [data.DatesStr num2cell(data.PCAScoresOverall)];
    labels = {'Date' data.FirmNames{:,:}};
    t6 = cell2table(vars,'VariableNames',labels);
    writetable(t6,out_file,'FileType','spreadsheet','Sheet','PCA Overall Scores','WriteRowNames',true);
    
end

%% MEASURES

function window_results = main_loop(window,group_delimiters,significance,robust)

    window_normalized = window;

    for j = 1:size(window_normalized,2)
        window_normalized_j = window_normalized(:,j);
        window_normalized_j = window_normalized_j - mean(window_normalized_j);
        window_normalized(:,j) = window_normalized_j / std(window_normalized_j);
    end

    window_normalized(isnan(window_normalized)) = 0;

    window_results = struct();

    adjacency_matrix = causal_adjacency(window,significance,robust);
    window_results.AdjacencyMatrix = adjacency_matrix;

    [dci,number_io,number_ioo] = calculate_indicators(adjacency_matrix,group_delimiters);
    window_results.DCI = dci;
    window_results.ConnectionsInOut = number_io;
    window_results.ConnectionsInOutOther = number_ioo;

    [bc,cc,dc,ec,kc,clustering_coefficients,degrees_in,degrees_out,degrees] = calculate_centralities(adjacency_matrix);
    window_results.BetweennessCentralities = bc;
    window_results.ClosenessCentralities = cc;
    window_results.DegreeCentralities = dc;
    window_results.EigenvectorCentralities = ec;
    window_results.KatzCentralities = kc;
    window_results.ClusteringCoefficients = clustering_coefficients;
    window_results.DegreesIn = degrees_in;
    window_results.DegreesOut = degrees_out;
    window_results.Degrees = degrees;

    [pca_coefficients,pca_scores,~,~,pca_explained] = pca(window_normalized,'Economy',false);
    window_results.PCACoefficients = pca_coefficients;
    window_results.PCAExplained = pca_explained;
    window_results.PCAScores = pca_scores;

end

function [bc,cc,dc,ec,kc,clustering_coefficients,degrees_in,degrees_out,degrees] = calculate_centralities(adjacency_matrix)

    adjacency_matrix_len = length(adjacency_matrix);

    bc = calculate_betweenness_centrality(adjacency_matrix,adjacency_matrix_len);
    [degrees_in,degrees_out,degrees,dc] = calculate_degree_centrality(adjacency_matrix,adjacency_matrix_len);
    cc = calculate_closeness_centrality(adjacency_matrix,adjacency_matrix_len);
    ec = calculate_eigenvector_centrality(adjacency_matrix);
    kc = calculate_katz_centrality(adjacency_matrix,adjacency_matrix_len);
    clustering_coefficients = calculate_clustering_coefficient(adjacency_matrix,adjacency_matrix_len,degrees);

end

function [dci,in_out,in_out_other] = calculate_indicators(adjacency_matrix,group_delimiters)

    n = size(adjacency_matrix,1);

    dci = sum(sum(adjacency_matrix)) / ((n ^ 2) - n);

    number_i = zeros(n,1);
    number_o = zeros(n,1);
    
    for i = 1:n     
        number_i(i) = sum(adjacency_matrix(:,i));
        number_o(i) = sum(adjacency_matrix(i,:));
    end

    in_out = (sum(number_i) + sum(number_o)) / (2 * (n - 1));
    
    if (isempty(group_delimiters))
        in_out_other = NaN;
    else
        group_delimiters_len = length(group_delimiters);
        number_ifo = zeros(n,1);
        number_oto = zeros(n,1);
        
        for i = 1:n
            group_1 = group_delimiters(1);
            group_n = group_delimiters(group_delimiters_len);
            
            if (i <= group_1)
                group_begin = 1;
                group_end = group_1;
            elseif (i > group_n)
                group_begin = group_n + 1;
                group_end = n;
            else
                for j = 1:group_delimiters_len-1
                    group_j0 = group_delimiters(j);
                    group_j1 = group_delimiters(j+1);

                    if ((i > group_j0) && (i <= group_j1))
                        group_begin = group_j0 + 1;
                        group_end = group_j1;
                    end
                end
            end

            number_ifo(i) = number_i(i) - sum(adjacency_matrix(group_begin:group_end,i));
            number_oto(i) = number_o(i) - sum(adjacency_matrix(i,group_begin:group_end));
        end

        in_out_other = (sum(number_ifo) + sum(number_oto)) / (2 * group_delimiters_len * (n / group_delimiters_len));
    end

end

function bc = calculate_betweenness_centrality(adjacency_matrix,adjacency_matrix_len)

    bc = zeros(1,adjacency_matrix_len);

    for i = 1:adjacency_matrix_len
        depth = 0;
        nsp = accumarray([1 i],1,[1 adjacency_matrix_len]);
        bfs = false(250,adjacency_matrix_len);
        fringe = adjacency_matrix(i,:);

        while ((nnz(fringe) > 0) && (depth <= 250))
            depth = depth + 1;
            nsp = nsp + fringe;
            bfs(depth,:) = logical(fringe);
            fringe = (fringe * adjacency_matrix) .* ~nsp;
        end

        [rows,cols,v] = find(nsp);
        v = 1 ./ v;
        
        nsp_inv = accumarray([rows.' cols.'],v,[1 adjacency_matrix_len]);

        bcu = ones(1,adjacency_matrix_len);

        for depth = depth:-1:2
            w = (bfs(depth,:) .* nsp_inv) .* bcu;
            bcu = bcu + ((adjacency_matrix * w.').' .* bfs(depth-1,:)) .* nsp;
        end

        bc = bc + sum(bcu,1);
    end

    bc = bc - adjacency_matrix_len;
    bc = (bc .* 2) ./ ((adjacency_matrix_len - 1) * (adjacency_matrix_len - 2));

end

function cc = calculate_closeness_centrality(adjacency_matrix,adjacency_matrix_len)

    cc = zeros(1,adjacency_matrix_len);

    for i = 1:adjacency_matrix_len
        paths = dijkstra_shortest_paths(adjacency_matrix,adjacency_matrix_len,i);
        paths_sum = sum(paths(~isinf(paths)));
        
        if (paths_sum ~= 0)
            cc(i) = 1 / paths_sum;
        end
    end

    cc = cc .* (adjacency_matrix_len - 1);

end

function clustering_coefficients = calculate_clustering_coefficient(adjacency_matrix,adjacency_matrix_len,degrees)

    if (issymmetric(adjacency_matrix))
        coefficient = 2;
    else
        coefficient = 1;
    end

    clustering_coefficients = zeros(adjacency_matrix_len,1);

    for i = 1:adjacency_matrix_len
        degree = degrees(i);

        if ((degree == 0) || (degree == 1))
            continue;
        end

        k_neighbors = find(adjacency_matrix(i,:) ~= 0);
        k_subgraph = adjacency_matrix(k_neighbors,k_neighbors);

        if (issymmetric(k_subgraph))
            k_subgraph_trace = trace(k_subgraph);
            
            if (k_subgraph_trace == 0)
                edges = sum(sum(k_subgraph)) / 2; 
            else
                edges = ((sum(sum(k_subgraph)) - k_subgraph_trace) / 2) + k_subgraph_trace;
            end
        else
            edges = sum(sum(k_subgraph));
        end

        clustering_coefficients(i) = (coefficient * edges) / (degree * (degree - 1));     
    end
    
    clustering_coefficients = clustering_coefficients.';

end

function [degrees_in,degrees_out,degrees,degree_centrality] = calculate_degree_centrality(adjacency_matrix,adjacency_matrix_len)

    degrees_in = sum(adjacency_matrix);
    degrees_out = sum(adjacency_matrix.');
    
    if (issymmetric(adjacency_matrix))
        degrees = degrees_in + diag(adjacency_matrix).';
    else
        degrees = degrees_in + degrees_out;
    end

    degree_centrality = degrees ./ (adjacency_matrix_len - 1);

end

function ec = calculate_eigenvector_centrality(adjacency_matrix)

	[eigen_vector,eigen_values] = eig(adjacency_matrix);
    [~,indices] = max(diag(eigen_values));

    ec = abs(eigen_vector(:,indices)).';
    ec = ec ./ sum(ec);

end

function kc = calculate_katz_centrality(adjacency_matrix,adjacency_matrix_len)

    kc = (eye(adjacency_matrix_len) - (adjacency_matrix .* 0.1)) \ ones(adjacency_matrix_len,1);
    kc = kc.' ./ (sign(sum(kc)) * norm(kc,'fro'));

end

function paths = dijkstra_shortest_paths(adjm,adjm_len,node)

    paths = Inf(1,adjm_len);
    paths(node) = 0;

    adjm_seq = 1:adjm_len;

    while (~isempty(adjm_seq))
        [~,idx] = min(paths(adjm_seq));
        adjm_seq_idx = adjm_seq(idx);

        for i = 1:length(adjm_seq)
            adjm_seq_i = adjm_seq(i);

            adjm_off = adjm(adjm_seq_idx,adjm_seq_i);
            sum_off = adjm_off + paths(adjm_seq_idx);
            
            if ((adjm_off > 0) && (paths(adjm_seq_i) > sum_off))
                paths(adjm_seq_i) = sum_off;
            end
        end

        adjm_seq = setdiff(adjm_seq,adjm_seq_idx);
    end

end

%% PLOTTING

function plot_indicators(data)

    connections_max = max(max([data.ConnectionsInOut data.ConnectionsInOutOther])) * 1.1;
    threshold_indices = data.DCI >= data.K;
    threshold = NaN(data.T,1);
    threshold(threshold_indices) = connections_max;

    f = figure('Name','Measures of Connectedness','Units','normalized','Position',[100 100 0.85 0.85]);
    
    sub_1 = subplot(2,1,1);
    plot(sub_1,data.DatesNum,data.DCI);
    hold on;
        plot(sub_1,data.DatesNum,repmat(data.K,[data.T 1]),'Color',[1 0.4 0.4]);
    hold off;
    t1 = title(sub_1,'Dynamic Causality Index');
    set(t1,'Units','normalized');
    t1_position = get(t1,'Position');
    set(t1,'Position',[0.4783 t1_position(2) t1_position(3)]);

    sub_2 = subplot(2,1,2);
    area_1 = area(sub_2,data.DatesNum,threshold,'EdgeColor','none','FaceColor',[1 0.4 0.4]);
    hold on;
        area_2 = area(sub_2,data.DatesNum,data.ConnectionsInOut,'EdgeColor','none','FaceColor','b');
        if (data.Groups == 0)
            area_3 = area(sub_2,data.DatesNum,NaN(data.T,1),'EdgeColor','none','FaceColor',[0.678 0.922 1]);
        else
            area_3 = area(sub_2,data.DatesNum,data.ConnectionsInOutOther,'EdgeColor','none','FaceColor',[0.678 0.922 1]);
        end
    hold off;
    set(sub_2,'YLim',[0 connections_max]);
    legend(sub_2,[area_2 area_3 area_1],'In & Out','In & Out - Other','Granger-causality Threshold','Location','best');
    t2 = title(sub_2,'Connections');
    set(t2,'Units','normalized');
    t2_position = get(t2,'Position');
    set(t2,'Position',[0.4783 t2_position(2) t2_position(3)]);

    set([sub_1 sub_2],'XLim',[data.DatesNum(data.Bandwidth) data.DatesNum(end)],'XTickLabelRotation',45);

    if (data.MonthlyTicks)
        datetick(sub_1,'x','mm/yyyy','KeepLimits','KeepTicks');
        datetick(sub_2,'x','mm/yyyy','KeepLimits','KeepTicks');
    else
        datetick(sub_1,'x','yyyy','KeepLimits');
        datetick(sub_2,'x','yyyy','KeepLimits');
    end
    
    t = figure_title('Measures of Connectedness');
    t_position = get(t,'Position');
    set(t,'Position',[t_position(1) -0.0157 t_position(3)]);
    
    pause(0.01);
    frame = get(f,'JavaFrame');
    set(frame,'Maximized',true);

end

function plot_network(data)

    if (data.Groups == 0)
        group_colors = repmat(lines(1),data.N,1);
    else
        group_colors = zeros(data.N,3);
        group_delimiters_len = length(data.GroupDelimiters);
        group_lines = lines(data.Groups);

        for i = 1:group_delimiters_len
            del = data.GroupDelimiters(i);

            if (i == 1)
                group_colors(1:del,:) = repmat(group_lines(i,:),del,1);
            else
                del_prev = data.GroupDelimiters(i-1) + 1;
                group_colors(del_prev:del,:) = repmat(group_lines(i,:),del-del_prev+1,1);
            end

            if (i == group_delimiters_len)
                group_colors(del+1:end,:) = repmat(group_lines(i+1,:),data.N-del,1);
            end
        end
    end
    
    if (isempty(data.Capitalizations))
        weights = nanmean(data.Degrees,1);
        weights = weights ./ mean(weights);
    else
        weights = mean(data.Capitalizations,1);
        weights = weights ./ mean(weights);
    end

	weights_min = min(weights);
	weights = (weights - weights_min) ./ (max(weights) - min(weights));
    weights = (weights .* 3.75) + 0.25;
    
    theta = linspace(0,(2 * pi),(data.N + 1)).';
    theta(end) = [];
    xy = [cos(theta) sin(theta)];
    [i,j] = find(data.AdjacencyMatrixAverage);
    [~,order] = sort(max(i,j));
    i = i(order);
    j = j(order);
    x = [xy(i,1) xy(j,1)].';
    y = [xy(i,2) xy(j,2)].';

    f = figure('Name','Network Graph','Units','normalized','Position',[100 100 0.85 0.85]);

    sub = subplot(100,1,10:100);

    hold on;
        for i = 1:size(x,2)
            index = ismember(xy,[x(1,i) y(1,i)],'rows');
            plot(sub,x(:,i),y(:,i),'Color',group_colors(index,:));
        end
    hold off;

    if (data.Groups == 0)
        hold on;
            for i = 1:size(xy,1)
                line(xy(i,1),xy(i,2),'Color',group_colors(i,:),'LineStyle','none','Marker','.','MarkerSize',(35 + (15 * weights(i))));
            end
        hold off;
    else
        group_delimiters_inc = data.GroupDelimiters + 1;

        lines_ref = NaN(data.Groups,1);
        lines_off = 1;

        hold on;
            for i = 1:size(xy,1)
                group_color = group_colors(i,:);
                line(xy(i,1),xy(i,2),'Color',group_color,'LineStyle','none','Marker','.','MarkerSize',(35 + (15 * weights(i))));

                if ((i == 1) || any(group_delimiters_inc == i))
                    lines_ref(lines_off) = line(xy(i,1),xy(i,2),'Color',group_color,'LineStyle','none','Marker','.','MarkerSize',35);
                    lines_off = lines_off + 1;
                end
            end
        hold off;

        legend(sub,lines_ref,data.GroupNames,'Units','normalized','Position',[0.85 0.12 0.001 0.001]);
    end

    axis(sub,[-1 1 -1 1]);
    axis equal off;

    labels = text((xy(:,1) .* 1.075), (xy(:,2) .* 1.075),data.FirmNames,'FontSize',10);
    set(labels,{'Rotation'},num2cell(theta * (180 / pi())));

    t = figure_title('Network Graph');
    t_position = get(t,'Position');
    set(t,'Position',[t_position(1) -0.0157 t_position(3)]);
    
    pause(0.01);
    frame = get(f,'JavaFrame');
    set(frame,'Maximized',true);

end

function plot_adjacency_matrix(data)

    a = data.AdjacencyMatrixAverage;
    a(logical(eye(data.N))) = 0.5;
    a = padarray(a,[1 1],'post');

    off = data.N + 0.5;

    f = figure('Name','Average Adjacency Matrix','Units','normalized','Position',[100 100 0.85 0.85]);

    pcolor(a);
    colormap([1 1 1; 0.65 0.65 0.65; 0.749 0.862 0.933])
    axis image;

    ax = gca();
    set(ax,'XAxisLocation','top','TickLength',[0 0],'YDir','reverse');
    set(ax,'XTick',1.5:off,'XTickLabels',data.FirmNames,'XTickLabelRotation',45,'YTick',1.5:off,'YTickLabels',data.FirmNames,'YTickLabelRotation',45);
    
    t = figure_title('Average Adjacency Matrix');
    t_position = get(t,'Position');
    set(t,'Position',[t_position(1) -0.0157 t_position(3)]);

    pause(0.01);
    frame = get(f,'JavaFrame');
    set(frame,'Maximized',true);

end

function plot_centralities(data)

    seq = 1:data.N;
    
    [bc,order] = sort(data.BetweennessCentralitiesAverage);
    bc_names = data.FirmNames(order);
    [cc,order] = sort(data.ClosenessCentralitiesAverage);
    cc_names = data.FirmNames(order);
    [dc,order] = sort(data.DegreeCentralitiesAverage);
    dc_names = data.FirmNames(order);
    [ec,order] = sort(data.EigenvectorCentralitiesAverage);
    ec_names = data.FirmNames(order);
    [kc,order] = sort(data.KatzCentralitiesAverage);
    kc_names = data.FirmNames(order);
    [clustering_coefficients,order] = sort(data.ClusteringCoefficientsAverage);
    clustering_coefficients_names = data.FirmNames(order);

    f = figure('Name','Average Centrality Measures','Units','normalized','Position',[100 100 0.85 0.85]);

    sub_1 = subplot(2,3,1);
    bar(sub_1,seq,bc,'FaceColor',[0.749 0.862 0.933]);
    set(sub_1,'XTickLabel',bc_names);
    title('Betweenness Centrality');
    
    sub_2 = subplot(2,3,2);
    bar(sub_2,seq,cc,'FaceColor',[0.749 0.862 0.933]);
    set(sub_2,'XTickLabel',cc_names);
    title('Closeness Centrality');
    
    sub_3 = subplot(2,3,3);
    bar(sub_3,seq,dc,'FaceColor',[0.749 0.862 0.933]);
    set(sub_3,'XTickLabel',dc_names);
    title('Degree Centrality');
    
    sub_4 = subplot(2,3,4);
    bar(sub_4,seq,ec,'FaceColor',[0.749 0.862 0.933]);
    set(sub_4,'XTickLabel',ec_names);
    title('Eigenvector Centrality');
    
    sub_5 = subplot(2,3,5);
    bar(sub_5,seq,kc,'FaceColor',[0.749 0.862 0.933]);
    set(sub_5,'XTickLabel',kc_names);
    title('Katz Centrality');

    sub_6 = subplot(2,3,6);
    bar(sub_6,seq,clustering_coefficients,'FaceColor',[0.749 0.862 0.933]);
    set(sub_6,'XTickLabel',clustering_coefficients_names);
    title('Clustering Coefficient');
    
    set([sub_1 sub_2 sub_3 sub_4 sub_5 sub_6],'XLim',[0 (data.N + 1)],'XTick',seq,'XTickLabelRotation',90);

    t = figure_title('Average Centrality Measures');
    t_position = get(t,'Position');
    set(t,'Position',[t_position(1) -0.0157 t_position(3)]);
    
    pause(0.01);
    frame = get(f,'JavaFrame');
    set(frame,'Maximized',true);

end

function plot_pca(data)

    coefficients = data.PCACoefficientsOverall(:,1:3);
    [coefficients_rows,coefficients_columns] = size(coefficients);
    [~,indices] = max(abs(coefficients),[],1);
    coefficients_max_len = sqrt(max(sum(coefficients.^2,2)));
    coefficients_columns_sign = sign(coefficients(indices + (0:coefficients_rows:((coefficients_columns-1)*coefficients_rows))));
    coefficients = bsxfun(@times,coefficients,coefficients_columns_sign);

    scores = data.PCAScoresOverall(:,1:3);
    scores_rows = size(scores,1);
    scores = bsxfun(@times,(coefficients_max_len .* (scores ./ max(abs(scores(:))))),coefficients_columns_sign);
    
    area_begin = zeros(coefficients_rows,1);
    area_end = NaN(coefficients_rows,1);
    x_area = [area_begin coefficients(:,1) area_end].';
    y_area = [area_begin coefficients(:,2) area_end].';
    z_area = [area_begin coefficients(:,3) area_end].';
    
    area_end = NaN(scores_rows,1);
    x_points = [scores(:,1) area_end]';
    y_points = [scores(:,2) area_end]';
    z_points = [scores(:,3) area_end]';

    limits_high = 1.1 * max(abs(coefficients(:)));
    limits_low = -limits_high;
    
    y_ticks = 0:10:100;
    y_labels = arrayfun(@(x)sprintf('%d%%',x),y_ticks,'UniformOutput',false);
    
    f = figure('Name','Principal Component Analysis','Units','normalized');

    sub_1 = subplot(1,2,1);
    line_1 = line(x_area(1:2,:),y_area(1:2,:),z_area(1:2,:),'LineStyle','-','Marker','none');
    line_2 = line(x_area(2:3,:),y_area(2:3,:),z_area(2:3,:),'LineStyle','none','Marker','.');
    set([line_1 line_2],'Color','b');
    line(x_points,y_points,z_points,'Color','r','LineStyle','none','Marker','.');
    view(sub_1,coefficients_columns);
    grid on;
    line([limits_low limits_high NaN 0 0 NaN 0 0],[0 0 NaN limits_low limits_high NaN 0 0],[0 0 NaN 0 0 NaN limits_low limits_high],'Color','k');
    axis tight;
    xlabel(sub_1,'PC 1');
    ylabel(sub_1,'PC 2');
    zlabel(sub_1,'PC 3');
    title('Coefficients & Scores');

    sub_2 = subplot(1,2,2);
    area_1 = area(sub_2,data.DatesNum,data.PCAExplainedSums(:,1),'FaceColor',[0.7 0.7 0.7]);
    hold on;
        area_2 = area(sub_2,data.DatesNum,data.PCAExplainedSums(:,2),'FaceColor','g');
        area_3 = area(sub_2,data.DatesNum,data.PCAExplainedSums(:,3),'FaceColor','b');
        area_4 = area(sub_2,data.DatesNum,data.PCAExplainedSums(:,4),'FaceColor','r');
    hold off;
    datetick('x','yyyy','KeepLimits');
    set([area_1 area_2 area_3 area_4],'EdgeColor','none');
    set(sub_2,'XLim',[data.DatesNum(data.Bandwidth) data.DatesNum(end)],'XTick',[],'YLim',[y_ticks(1) y_ticks(end)],'YTick',y_ticks,'YTickLabel',y_labels);
    legend(sub_2,sprintf('PC 4-%d',data.N),'PC 3','PC 2','PC 1','Location','southeast');
    title('Explained Variance');

    t = figure_title('Principal Component Analysis');
    t_position = get(t,'Position');
    set(t,'Position',[t_position(1) -0.0157 t_position(3)]);
    
    pause(0.01);
    frame = get(f,'JavaFrame');
    set(frame,'Maximized',true);

end
