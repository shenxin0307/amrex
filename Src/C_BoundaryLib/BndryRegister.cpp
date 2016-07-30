
#include <winstd.H>
#include <BndryRegister.H>
#include <Orientation.H>
#include <Utility.H>
#include <limits>

namespace {
    static const Real BL_SAFE_BOGUS = std::numeric_limits<Real>::quiet_NaN();
}

BndryRegister::BndryRegister () {}

BndryRegister::~BndryRegister () {}

BndryRegister::BndryRegister (const BoxArray& grids,
                              int             in_rad,
                              int             out_rad,
                              int             extent_rad,
                              int             ncomp,
			      ParallelDescriptor::Color color)
    :
    grids(grids)
{
    BL_ASSERT(ncomp > 0);
    BL_ASSERT(grids[0].cellCentered());

    for (OrientationIter face; face; ++face)
    {
        define(face(),IndexType::TheCellType(),in_rad,out_rad,extent_rad,ncomp,color);
    }
}

void
BndryRegister::init (const BndryRegister& src)
{
    grids = src.grids;

    for (int i = 0; i < 2*BL_SPACEDIM; i++)
    {
        bndry[i].define(src.bndry[i].boxArray(), src.bndry[i].nComp(), src.color());

        for (FabSetIter mfi(src.bndry[i]); mfi.isValid(); ++mfi)
        {
            bndry[i][mfi].copy(src.bndry[i][mfi]);
        }
    }
}

BndryRegister::BndryRegister (const BndryRegister& src)
{
    init(src);
}

BndryRegister&
BndryRegister::operator= (const BndryRegister& src)
{
    if (this != &src)
    {
        if (grids.size() > 0)
        {
            grids.clear();

            for (int i = 0; i < 2*BL_SPACEDIM; i++)
                bndry[i].clear();
        }

        init(src);
    }
    return *this;
}

BATransformer
BndryRegister::make_transformer (Orientation face, IndexType typ,
				 int in_rad, int out_rad, int extent_rad)
{
    const IntVect& nodal_shft = typ.ixType();

    IntVect lo(D_DECL(-extent_rad,-extent_rad,-extent_rad));
    IntVect hi(D_DECL( extent_rad, extent_rad, extent_rad));
    hi += nodal_shft;

    int i = face.coordDir();
    if (face.isLow()) {
	lo[i] = nodal_shft[i] - out_rad;
	hi[i] = lo[i] + in_rad + out_rad - 1;
    } else {
	hi[i] = out_rad;
	lo[i] = hi[i] - (in_rad+out_rad) + 1;
    }

    return BATransformer(typ, lo, hi);
}

void
BndryRegister::define (Orientation _face,
                       IndexType   _typ,
                       int         _in_rad,
                       int         _out_rad,
                       int         _extent_rad,
                       int         _ncomp,
		       ParallelDescriptor::Color color)
{
    const BATransformer& bbatrans
	= make_transformer(_face,_typ,_in_rad,_out_rad,_extent_rad);
    BoxArray fsBA(grids, bbatrans);

    FabSet& fabs = bndry[_face];

    BL_ASSERT(fabs.size() == 0);

    fabs.define(fsBA,_ncomp,color);
    // 
    // Go ahead and assign values to the boundary register fabs
    // since in some places APPLYBC (specifically in the tensor
    // operator) the boundary registers are used for a few calculations
    // before the masks are tested to see if you need them.
    //
    fabs.setVal(BL_SAFE_BOGUS);
}

void
BndryRegister::define (Orientation                _face,
                       IndexType                  _typ,
                       int                        _in_rad,
                       int                        _out_rad,
                       int                        _extent_rad,
                       int                        _ncomp,
                       const DistributionMapping& _dm)
{
    const BATransformer& bbatrans
	= make_transformer(_face,_typ,_in_rad,_out_rad,_extent_rad);
    BoxArray fsBA(grids, bbatrans);

    FabSet& fabs = bndry[_face];

    BL_ASSERT(fabs.size() == 0);

    fabs.define(fsBA,_ncomp,_dm);
    // 
    // Go ahead and assign values to the boundary register fabs
    // since in some places APPLYBC (specifically in the tensor
    // operator) the boundary registers are used for a few calculations
    // before the masks are tested to see if you need them.
    //
    fabs.setVal(BL_SAFE_BOGUS);
}

void
BndryRegister::setBoxes (const BoxArray& _grids)
{
    BL_ASSERT(grids.size() == 0);
    BL_ASSERT(_grids.size() > 0);
    BL_ASSERT(_grids[0].cellCentered());

    grids = _grids;
    //
    // Check that bndry regions are not allocated.
    //
    for (int k = 0; k < 2*BL_SPACEDIM; k++)
        BL_ASSERT(bndry[k].size() == 0);
}

void BndryRegister::setVal (Real v)
{
    for (OrientationIter face; face; ++face)
    {
        bndry[face()].setVal(v);
    }
}

BndryRegister&
BndryRegister::operator+= (const BndryRegister& rhs)
{
    BL_ASSERT(grids == rhs.grids);
    for (OrientationIter face; face; ++face) {
#ifdef _OPENMP
#pragma omp parallel
#endif
	for (FabSetIter bfsi(rhs[face()]); bfsi.isValid(); ++bfsi) {
	    bndry[face()][bfsi] += rhs[face()][bfsi];
	}
    }
    return *this;
}

BndryRegister&
BndryRegister::plus (const BndryRegister& rhs)
{
    return operator+=(rhs);
}

BndryRegister&
BndryRegister::linComb (Real            a,
                        const MultiFab& mfa,
                        int             a_comp,
                        Real            b,
                        const MultiFab& mfb,
                        int             b_comp,
                        int             dest_comp,
                        int             num_comp,
                        int             n_ghost)
{
    for (OrientationIter face; face; ++face)
    {
        bndry[face()].linComb(a,
                              mfa,
                              a_comp,
                              b,
                              mfb,
                              b_comp,
                              dest_comp,
                              num_comp,
                              n_ghost);
    }
    return *this;
}

BndryRegister&
BndryRegister::copyFrom (const MultiFab& src,
                         int             nghost,
                         int             src_comp,
                         int             dest_comp,
                         int             num_comp)
{
    for (OrientationIter face; face; ++face)
    {
        bndry[face()].copyFrom(src,nghost,src_comp,dest_comp,num_comp);
    }
    return *this;
}

BndryRegister&
BndryRegister::plusFrom (const MultiFab& src,
                         int             nghost,
                         int             src_comp,
                         int             dest_comp,
                         int             num_comp)
{
    for (OrientationIter face; face; ++face)
    {
        bndry[face()].plusFrom(src,nghost,src_comp,dest_comp,num_comp);
    }
    return *this;
}

void
BndryRegister::write (const std::string& name, std::ostream& os) const
{
    if (ParallelDescriptor::IOProcessor(color()))
    {
        grids.writeOn(os);
        os << '\n';
    }

    for (OrientationIter face; face; ++face)
    {
        //
        // Take name here and make a "new" name unique to each face.
        // Simplest thing would probably to append "_n" to the name,
        // where n is the integer value of face().
        //
        const int i = face();
        BL_ASSERT(i >= 0 && i <= 7);

        std::string facename = BoxLib::Concatenate(name + '_', i, 1);

        bndry[face()].write(facename);
    }
}

void
BndryRegister::read (const std::string& name, std::istream& is)
{
    grids.readFrom(is);

    for (OrientationIter face; face; ++face)
    {
        //
        // Take name here and make a "new" name unique to each face.
        // Simplest thing would probably to append "_n" to the name,
        // where n is the integer value of face().
        //
        const int i = face();
        BL_ASSERT(i >= 0 && i <= 7);

        std::string facename = BoxLib::Concatenate(name + '_', i, 1);

        bndry[face()].read(facename);
    }
}

void
BndryRegister::AddProcsToComp(int ioProcNumSCS, int ioProcNumAll,
                              int scsMyId, MPI_Comm scsComm)
{
  // ---- BoxArrays
  BoxLib::BroadcastBoxArray(grids, scsMyId, ioProcNumSCS, scsComm);

  // ---- FabSet
  for(int i(0); i < (2 * BL_SPACEDIM); ++i) {
    bndry[i].AddProcsToComp(ioProcNumSCS, ioProcNumAll, scsMyId, scsComm);
  }
}



